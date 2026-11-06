/* libcurl transport for AgentLean.Driver (Lean has no HTTP/TLS client of its own).
 * @tg: implements:: [[openspec:host-abi#Lean driver]] */
#include <lean/lean.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* libcurl is loaded at run time, so building and linking need no curl headers or flags. */
typedef void CURL;
struct curl_slist;
typedef int CURLcode;
#define CURLE_OK 0
#define CURLOPT_URL 10002
#define CURLOPT_HTTPHEADER 10023
#define CURLOPT_POSTFIELDS 10015
#define CURLOPT_POSTFIELDSIZE 60
#define CURLOPT_WRITEFUNCTION 20011
#define CURLOPT_WRITEDATA 10001
#define CURLOPT_TIMEOUT 13
#define CURLOPT_NOSIGNAL 99
#define CURLINFO_RESPONSE_CODE 0x200002
#define CURL_GLOBAL_DEFAULT 3

static struct {
  int (*global_init)(long);
  CURL *(*easy_init)(void);
  int (*easy_setopt)(CURL *, int, ...);
  CURLcode (*easy_perform)(CURL *);
  int (*easy_getinfo)(CURL *, int, ...);
  const char *(*easy_strerror)(CURLcode);
  void (*easy_cleanup)(CURL *);
  struct curl_slist *(*slist_append)(struct curl_slist *, const char *);
  void (*slist_free_all)(struct curl_slist *);
} C;

/* @tg: implements:: [[adr:0016]] */
static const char *load_curl(void) {
  static int state = 0; /* 0 untried, 1 ok, -1 failed */
  if (state) return state > 0 ? NULL : "libcurl not found";
  const char *names[] = {"libcurl.4.dylib", "libcurl.dylib", "libcurl.so.4", "libcurl.so", NULL};
  void *h = NULL;
  for (int i = 0; names[i] && !h; i++) h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
  if (!h) { state = -1; return "libcurl not found"; }
#define SYM(field, name) *(void **)(&C.field) = dlsym(h, name); if (!C.field) { state = -1; return "libcurl symbol missing: " name; }
  SYM(global_init, "curl_global_init")
  SYM(easy_init, "curl_easy_init")
  SYM(easy_setopt, "curl_easy_setopt")
  SYM(easy_perform, "curl_easy_perform")
  SYM(easy_getinfo, "curl_easy_getinfo")
  SYM(easy_strerror, "curl_easy_strerror")
  SYM(easy_cleanup, "curl_easy_cleanup")
  SYM(slist_append, "curl_slist_append")
  SYM(slist_free_all, "curl_slist_free_all")
#undef SYM
  C.global_init(CURL_GLOBAL_DEFAULT);
  state = 1;
  return NULL;
}

typedef struct { char *data; size_t len, cap; } buf_t;

static size_t on_data(char *p, size_t size, size_t n, void *ud) {
  buf_t *b = (buf_t *)ud;
  size_t k = size * n;
  if (b->len + k + 1 > b->cap) {
    size_t cap = (b->cap ? b->cap * 2 : 4096);
    while (cap < b->len + k + 1) cap *= 2;
    char *d = (char *)realloc(b->data, cap);
    if (!d) return 0;
    b->data = d; b->cap = cap;
  }
  memcpy(b->data + b->len, p, k);
  b->len += k;
  b->data[b->len] = 0;
  return k;
}

static lean_obj_res pair(uint32_t status, const char *s, size_t n) {
  lean_object *p = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(p, 0, lean_box_uint32(status));
  lean_ctor_set(p, 1, lean_mk_string_from_bytes(s ? s : "", s ? n : 0));
  return p;
}

/* POST `body` to `url` with `headers` (Array (String × String)).
 * Returns (status, body); status 0 means a transport error and the string is its message. */
LEAN_EXPORT lean_obj_res agentlean_http_post(b_lean_obj_arg url, b_lean_obj_arg headers, b_lean_obj_arg body,
                                             uint32_t timeout_s) {
  const char *missing = load_curl();
  if (missing) return lean_io_result_mk_ok(pair(0, missing, strlen(missing)));
  CURL *c = C.easy_init();
  if (!c) return lean_io_result_mk_ok(pair(0, "curl_easy_init failed", 21));
  struct curl_slist *hs = NULL;
  size_t n = lean_array_size(headers);
  for (size_t i = 0; i < n; i++) {
    lean_object *kv = lean_array_get_core(headers, i);
    const char *k = lean_string_cstr(lean_ctor_get(kv, 0));
    const char *v = lean_string_cstr(lean_ctor_get(kv, 1));
    size_t len = strlen(k) + strlen(v) + 3;
    char *line = (char *)malloc(len);
    snprintf(line, len, "%s: %s", k, v);
    hs = C.slist_append(hs, line);
    free(line);
  }
  buf_t out = {0};
  C.easy_setopt(c, CURLOPT_URL, lean_string_cstr(url));
  C.easy_setopt(c, CURLOPT_HTTPHEADER, hs);
  C.easy_setopt(c, CURLOPT_POSTFIELDS, lean_string_cstr(body));
  C.easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)(lean_string_size(body) - 1));
  C.easy_setopt(c, CURLOPT_WRITEFUNCTION, on_data);
  C.easy_setopt(c, CURLOPT_WRITEDATA, &out);
  C.easy_setopt(c, CURLOPT_TIMEOUT, (long)timeout_s);
  C.easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
  CURLcode rc = C.easy_perform(c);
  lean_object *res;
  if (rc != CURLE_OK) {
    const char *m = C.easy_strerror(rc);
    res = pair(0, m, strlen(m));
  } else {
    long status = 0;
    C.easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    res = pair((uint32_t)status, out.data, out.len);
  }
  free(out.data);
  C.slist_free_all(hs);
  C.easy_cleanup(c);
  return lean_io_result_mk_ok(res);
}
