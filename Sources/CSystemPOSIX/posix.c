#if defined(__linux__)
// GNU declarations must be enabled before any libc header is parsed.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "CSystemPOSIX.h"
#include <fcntl.h>
#include <stdio.h>
#include <sys/xattr.h>
#include <sys/stat.h>

int computer_mcp_renameat_noreplace(int source, const char *name, int target, const char *leaf) {
  return renameat2(source, name, target, leaf, RENAME_NOREPLACE);
}

int computer_mcp_spawn_addfchdir(posix_spawn_file_actions_t *actions, int descriptor) {
  return posix_spawn_file_actions_addfchdir_np(actions, descriptor);
}

int computer_mcp_openat_identity(int parent, const char *name) {
  return openat(parent, name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
}

// A successful statx without STATX_BTIME is the only unsupported-birth-time fallback.
int computer_mcp_birthtime(int descriptor, int64_t *seconds, int64_t *nanoseconds) {
  struct statx value;
  if (statx(descriptor, "", AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW, STATX_BTIME, &value) != 0) return -1;
  if (!(value.stx_mask & STATX_BTIME)) return 0;
  *seconds = value.stx_btime.tv_sec;
  *nanoseconds = value.stx_btime.tv_nsec;
  return 1;
}

int computer_mcp_chmod_identity(int descriptor, mode_t mode) {
  // O_PATH handles work for mode-000 directories; procfs resolves this held inode.
  char path[64];
  snprintf(path, sizeof(path), "/proc/self/fd/%d", descriptor);
  return chmod(path, mode);
}

ssize_t computer_mcp_flistxattr(int descriptor, char *names, size_t size) {
  return flistxattr(descriptor, names, size);
}

ssize_t computer_mcp_fgetxattr(int descriptor, const char *name, void *value, size_t size) {
  return fgetxattr(descriptor, name, value, size);
}

int computer_mcp_fsetxattr(int descriptor, const char *name, const void *value, size_t size) {
  return fsetxattr(descriptor, name, value, size, 0);
}

int computer_mcp_fremovexattr(int descriptor, const char *name) {
  return fremovexattr(descriptor, name);
}
#endif
