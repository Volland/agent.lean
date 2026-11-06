/* agent.lean C ABI shim over the Lean exports in AgentLean/Abi.lean.
 * @tg: implements:: [[openspec:host-abi#Pull-based driving]]
 * @tg: implements:: [[openspec:host-abi#Handle thread confinement]]
 * @tg: implements:: [[openspec:host-abi#JSON payloads]]
 * @tg: implements:: [[adr:0007]] */
#include "agent.h"
#include <lean/lean.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* Provided by the application bundle (generated app_init.c): runs the module initializers that
 * register the application's agents. */
extern void agent_app_initialize(void);
extern void lean_initialize_runtime_module(void);
extern void lean_initialize_thread(void);

extern lean_object *agentlean_env(lean_object *unit);
extern lean_object *agentlean_new_in(lean_object *env, lean_object *config);
extern lean_object *agentlean_restore_in(lean_object *env, lean_object *snapshot);
extern lean_object *agentlean_feed(lean_object *h, lean_object *event);
extern lean_object *agentlean_next(lean_object *h);
extern lean_object *agentlean_snapshot(lean_object *h);
extern lean_object *agentlean_trace(lean_object *h);
extern lean_object *agentlean_audit(lean_object *h);
extern lean_object *agentlean_error(lean_object *h);
extern uint8_t agentlean_done(lean_object *h);
extern uint8_t agentlean_sensitive(lean_object *h);
extern uint64_t agentlean_trace_len(lean_object *h);

struct agent {
  lean_object *h;
};

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static lean_object *g_env = NULL; /* registered agents, persistent after init */
static _Thread_local int t_ready = 0;

/* @tg: implements:: [[adr:0017]] */
static void init_once(void) {
  lean_initialize_runtime_module();
  agent_app_initialize();
  /* Every handle shares the registered agents. Mark them persistent (no reference counting) so
   * handles driven concurrently on different threads never race on their counts. */
  lean_object *r = agentlean_env(lean_box(0));
  if (lean_io_result_is_ok(r)) {
    g_env = lean_io_result_get_value(r);
    lean_inc(g_env);
    lean_mark_persistent(g_env);
  }
  lean_dec(r);
  lean_io_mark_end_initialization();
  t_ready = 1;
}

/* Every entry point: initialize the runtime once, and register this thread with it once. */
static void enter(void) {
  pthread_once(&g_once, init_once);
  if (!t_ready) {
    lean_initialize_thread();
    t_ready = 1;
  }
}

static lean_object *bytes(const uint8_t *p, size_t n) {
  lean_object *o = lean_alloc_sarray(1, n, n);
  if (n) memcpy(lean_sarray_cptr(o), p, n);
  return o;
}

static agent_buf_t take_string(lean_object *s) {
  agent_buf_t b = {NULL, 0};
  size_t n = lean_string_size(s) - 1;
  b.data = (uint8_t *)malloc(n + 1);
  if (b.data) {
    memcpy(b.data, lean_string_cstr(s), n);
    b.data[n] = 0;
    b.len = n;
  }
  lean_dec(s);
  return b;
}

static agent_t *from_except(lean_object *ex, agent_buf_t *err) { /* Except String Handle, owned */
  if (lean_obj_tag(ex) == 0) { /* Except.error */
    lean_object *msg = lean_ctor_get(ex, 0);
    lean_inc(msg);
    lean_dec(ex);
    if (err) *err = take_string(msg); else lean_dec(msg);
    return NULL;
  }
  lean_object *h = lean_ctor_get(ex, 0);
  lean_inc(h);
  lean_dec(ex);
  agent_t *a = (agent_t *)malloc(sizeof(agent_t));
  if (!a) { lean_dec(h); return NULL; }
  a->h = h;
  if (err) *err = (agent_buf_t){NULL, 0};
  return a;
}

static int no_env(agent_buf_t *err) {
  if (g_env) return 0;
  if (err) *err = (agent_buf_t){(uint8_t *)strdup("initialization failed"), 21};
  return 1;
}

agent_t *agent_new(const uint8_t *config, size_t len, agent_buf_t *err) {
  enter();
  if (no_env(err)) return NULL;
  return from_except(agentlean_new_in(g_env, bytes(config, len)), err);
}

agent_t *agent_restore(const uint8_t *snapshot, size_t len, agent_buf_t *err) {
  enter();
  if (no_env(err)) return NULL;
  return from_except(agentlean_restore_in(g_env, bytes(snapshot, len)), err);
}

int agent_feed(agent_t *a, const uint8_t *event, size_t len) {
  if (!a) return AGENT_FAILED;
  enter();
  lean_object *r = agentlean_feed(a->h, bytes(event, len)); /* consumes a->h */
  lean_object *h = lean_ctor_get(r, 0);
  int code = (int)lean_unbox_uint32(lean_ctor_get(r, 1));
  lean_inc(h);
  lean_dec(r);
  a->h = h;
  return code;
}

int agent_next_effect(agent_t *a, agent_buf_t *out) {
  if (!a) return 0;
  enter();
  lean_object *r = agentlean_next(a->h); /* (Option String × Handle) */
  lean_object *opt = lean_ctor_get(r, 0);
  lean_object *h = lean_ctor_get(r, 1);
  lean_inc(h);
  int has = !lean_is_scalar(opt);
  if (has) {
    lean_object *s = lean_ctor_get(opt, 0);
    lean_inc(s);
    *out = take_string(s);
  }
  lean_dec(r);
  a->h = h;
  return has;
}

#define BORROWED_CALL(fn, a) (lean_inc((a)->h), fn((a)->h))

agent_buf_t agent_snapshot(agent_t *a) { enter(); return take_string(BORROWED_CALL(agentlean_snapshot, a)); }
agent_buf_t agent_trace(agent_t *a) { enter(); return take_string(BORROWED_CALL(agentlean_trace, a)); }
agent_buf_t agent_audit(agent_t *a) { enter(); return take_string(BORROWED_CALL(agentlean_audit, a)); }
agent_buf_t agent_last_error(agent_t *a) { enter(); return take_string(BORROWED_CALL(agentlean_error, a)); }
int agent_is_done(agent_t *a) { enter(); return BORROWED_CALL(agentlean_done, a); }
int agent_is_sensitive(agent_t *a) { enter(); return BORROWED_CALL(agentlean_sensitive, a); }
uint64_t agent_trace_len(agent_t *a) { enter(); return BORROWED_CALL(agentlean_trace_len, a); }

void agent_buf_free(agent_buf_t b) { free(b.data); }

void agent_free(agent_t *a) {
  if (!a) return;
  enter();
  lean_dec(a->h);
  free(a);
}
