/* agent.lean: POSIX implementation of the libuv subset declared in uv.h. */
/* @tg: implements:: [[adr:0013]] */
#include "uv.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void fill(uv_stat_t *o, const struct stat *s) {
  memset(o, 0, sizeof *o);
  o->st_dev = s->st_dev; o->st_mode = s->st_mode; o->st_nlink = s->st_nlink;
  o->st_uid = s->st_uid; o->st_gid = s->st_gid; o->st_rdev = s->st_rdev;
  o->st_ino = s->st_ino; o->st_size = s->st_size; o->st_blksize = s->st_blksize; o->st_blocks = s->st_blocks;
#if defined(__APPLE__)
  o->st_atim.tv_sec = s->st_atimespec.tv_sec; o->st_atim.tv_nsec = s->st_atimespec.tv_nsec;
  o->st_mtim.tv_sec = s->st_mtimespec.tv_sec; o->st_mtim.tv_nsec = s->st_mtimespec.tv_nsec;
  o->st_ctim.tv_sec = s->st_ctimespec.tv_sec; o->st_ctim.tv_nsec = s->st_ctimespec.tv_nsec;
#else
  o->st_atim.tv_sec = s->st_atim.tv_sec; o->st_atim.tv_nsec = s->st_atim.tv_nsec;
  o->st_mtim.tv_sec = s->st_mtim.tv_sec; o->st_mtim.tv_nsec = s->st_mtim.tv_nsec;
  o->st_ctim.tv_sec = s->st_ctim.tv_sec; o->st_ctim.tv_nsec = s->st_ctim.tv_nsec;
#endif
}

static int done(uv_fs_t *req, int r) { req->result = r < 0 ? -errno : r; return r < 0 ? -errno : r; }

int uv_fs_stat(uv_loop_t *l, uv_fs_t *req, const char *path, uv_fs_cb cb) {
  (void)l; (void)cb; struct stat s; req->path = NULL;
  int r = stat(path, &s); if (r == 0) fill(&req->statbuf, &s); return done(req, r);
}
int uv_fs_lstat(uv_loop_t *l, uv_fs_t *req, const char *path, uv_fs_cb cb) {
  (void)l; (void)cb; struct stat s; req->path = NULL;
  int r = lstat(path, &s); if (r == 0) fill(&req->statbuf, &s); return done(req, r);
}
int uv_fs_link(uv_loop_t *l, uv_fs_t *req, const char *path, const char *np, uv_fs_cb cb) {
  (void)l; (void)cb; req->path = NULL; return done(req, link(path, np));
}
int uv_fs_unlink(uv_loop_t *l, uv_fs_t *req, const char *path, uv_fs_cb cb) {
  (void)l; (void)cb; req->path = NULL; return done(req, unlink(path));
}
int uv_fs_mkdtemp(uv_loop_t *l, uv_fs_t *req, const char *tpl, uv_fs_cb cb) {
  (void)l; (void)cb; req->path = strdup(tpl);
  if (!req->path) return done(req, (errno = ENOMEM, -1));
  return done(req, mkdtemp(req->path) ? 0 : -1);
}
int uv_fs_mkstemp(uv_loop_t *l, uv_fs_t *req, const char *tpl, uv_fs_cb cb) {
  (void)l; (void)cb; req->path = strdup(tpl);
  if (!req->path) return done(req, (errno = ENOMEM, -1));
  return done(req, mkstemp(req->path));
}
void uv_fs_req_cleanup(uv_fs_t *req) { free(req->path); req->path = NULL; }

int uv_os_tmpdir(char *buf, size_t *size) {
  const char *keys[] = {"TMPDIR", "TMP", "TEMP", "TEMPDIR"};
  const char *d = NULL;
  for (unsigned i = 0; i < 4 && !d; i++) { d = getenv(keys[i]); if (d && !*d) d = NULL; }
  if (!d) d = "/tmp";
  size_t n = strlen(d);
  if (n > 1 && d[n - 1] == '/') n--;
  if (n + 1 > *size) { *size = n + 1; return UV_ENOBUFS; }
  memcpy(buf, d, n); buf[n] = 0; *size = n; return 0;
}
const char *uv_strerror(int err) { return strerror(err < 0 ? -err : err); }
int uv_translate_sys_error(int e) { return e <= 0 ? e : -e; }
