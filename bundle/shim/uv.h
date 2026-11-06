/* agent.lean: minimal POSIX stand-in for the libuv subset the Lean runtime core uses.
 * The bundle drops libuv (event loop, sockets) because the agent runtime does no IO of its own;
 * only file metadata, temp files, links and error-code translation remain, done with POSIX here. */
#pragma once
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif

#define UV_VERSION_HEX 0x013200 /* behave like libuv 1.50 for errno mapping */

#ifndef ENODATA
#define ENODATA 9919
#endif
#ifndef ETXTBSY
#define ETXTBSY 9920
#endif
#define UV__ERR(x) (-(x))
#define UV_E2BIG UV__ERR(E2BIG)
#define UV_EACCES UV__ERR(EACCES)
#define UV_EADDRINUSE UV__ERR(EADDRINUSE)
#define UV_EADDRNOTAVAIL UV__ERR(EADDRNOTAVAIL)
#define UV_EAFNOSUPPORT UV__ERR(EAFNOSUPPORT)
#define UV_EAGAIN UV__ERR(EAGAIN)
#define UV_EBADF UV__ERR(EBADF)
#define UV_EBUSY UV__ERR(EBUSY)
#define UV_ECONNABORTED UV__ERR(ECONNABORTED)
#define UV_ECONNREFUSED UV__ERR(ECONNREFUSED)
#define UV_ECONNRESET UV__ERR(ECONNRESET)
#define UV_EDESTADDRREQ UV__ERR(EDESTADDRREQ)
#define UV_EEXIST UV__ERR(EEXIST)
#define UV_EFAULT UV__ERR(EFAULT)
#define UV_EFBIG UV__ERR(EFBIG)
#define UV_EHOSTUNREACH UV__ERR(EHOSTUNREACH)
#define UV_EILSEQ UV__ERR(EILSEQ)
#define UV_EINTR UV__ERR(EINTR)
#define UV_EINVAL UV__ERR(EINVAL)
#define UV_EIO UV__ERR(EIO)
#define UV_EISCONN UV__ERR(EISCONN)
#define UV_EISDIR UV__ERR(EISDIR)
#define UV_ELOOP UV__ERR(ELOOP)
#define UV_EMFILE UV__ERR(EMFILE)
#define UV_EMLINK UV__ERR(EMLINK)
#define UV_EMSGSIZE UV__ERR(EMSGSIZE)
#define UV_ENAMETOOLONG UV__ERR(ENAMETOOLONG)
#define UV_ENETDOWN UV__ERR(ENETDOWN)
#define UV_ENETUNREACH UV__ERR(ENETUNREACH)
#define UV_ENFILE UV__ERR(ENFILE)
#define UV_ENOBUFS UV__ERR(ENOBUFS)
#define UV_ENODATA UV__ERR(ENODATA)
#define UV_ENODEV UV__ERR(ENODEV)
#define UV_ENOENT UV__ERR(ENOENT)
#define UV_ENOEXEC UV__ERR(ENOEXEC)
#define UV_ENOMEM UV__ERR(ENOMEM)
#define UV_ENOPROTOOPT UV__ERR(ENOPROTOOPT)
#define UV_ENOSPC UV__ERR(ENOSPC)
#define UV_ENOSYS UV__ERR(ENOSYS)
#define UV_ENOTCONN UV__ERR(ENOTCONN)
#define UV_ENOTDIR UV__ERR(ENOTDIR)
#define UV_ENOTEMPTY UV__ERR(ENOTEMPTY)
#define UV_ENOTSOCK UV__ERR(ENOTSOCK)
#define UV_ENOTSUP UV__ERR(ENOTSUP)
#define UV_ENOTTY UV__ERR(ENOTTY)
#define UV_ENXIO UV__ERR(ENXIO)
#define UV_EPERM UV__ERR(EPERM)
#define UV_EPIPE UV__ERR(EPIPE)
#define UV_EPROTO UV__ERR(EPROTO)
#define UV_EPROTONOSUPPORT UV__ERR(EPROTONOSUPPORT)
#define UV_EPROTOTYPE UV__ERR(EPROTOTYPE)
#define UV_ERANGE UV__ERR(ERANGE)
#define UV_EROFS UV__ERR(EROFS)
#define UV_ESPIPE UV__ERR(ESPIPE)
#define UV_ESRCH UV__ERR(ESRCH)
#define UV_ETIMEDOUT UV__ERR(ETIMEDOUT)
#define UV_ETXTBSY UV__ERR(ETXTBSY)
#define UV_EXDEV UV__ERR(EXDEV)

typedef struct { long tv_sec; long tv_nsec; } uv_timespec_t;
typedef struct {
  uint64_t st_dev, st_mode, st_nlink, st_uid, st_gid, st_rdev, st_ino, st_size, st_blksize, st_blocks, st_flags, st_gen;
  uv_timespec_t st_atim, st_mtim, st_ctim, st_birthtim;
} uv_stat_t;
typedef struct uv_loop_s uv_loop_t;
typedef struct uv_fs_s uv_fs_t;
typedef void (*uv_fs_cb)(uv_fs_t *);
struct uv_fs_s { ssize_t result; char *path; uv_stat_t statbuf; };

int uv_fs_stat(uv_loop_t *, uv_fs_t *, const char *path, uv_fs_cb);
int uv_fs_lstat(uv_loop_t *, uv_fs_t *, const char *path, uv_fs_cb);
int uv_fs_link(uv_loop_t *, uv_fs_t *, const char *path, const char *new_path, uv_fs_cb);
int uv_fs_unlink(uv_loop_t *, uv_fs_t *, const char *path, uv_fs_cb);
int uv_fs_mkdtemp(uv_loop_t *, uv_fs_t *, const char *tpl, uv_fs_cb);
int uv_fs_mkstemp(uv_loop_t *, uv_fs_t *, const char *tpl, uv_fs_cb);
void uv_fs_req_cleanup(uv_fs_t *);
int uv_os_tmpdir(char *buffer, size_t *size);
const char *uv_strerror(int err);
int uv_translate_sys_error(int sys_errno);

#ifdef __cplusplus
}
#endif
