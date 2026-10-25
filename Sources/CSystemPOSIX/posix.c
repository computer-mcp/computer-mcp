#if defined(__linux__)
// GNU declarations must be enabled before any libc header is parsed.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "CSystemPOSIX.h"
#include <fcntl.h>
#include <stdio.h>
#include <sys/xattr.h>
#include <errno.h>
#include <string.h>
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

// Writes the handle type followed by the handle bytes. With a MAX_HANDLE_SZ buffer,
// EOPNOTSUPP (no export operations) and EOVERFLOW (the filesystem cannot encode this
// inode) mean there is no generation, as do ENOSYS and EPERM from kernels or seccomp
// policies without the call; every other error is reported.
int computer_mcp_file_handle(int descriptor, unsigned char *bytes, size_t capacity, size_t *count) {
  union {
    struct file_handle handle;
    unsigned char storage[sizeof(struct file_handle) + MAX_HANDLE_SZ];
  } value;
  int mount;
  value.handle.handle_bytes = MAX_HANDLE_SZ;
  if (name_to_handle_at(descriptor, "", &value.handle, &mount, AT_EMPTY_PATH) != 0) {
    return errno == EOPNOTSUPP || errno == EOVERFLOW || errno == ENOSYS || errno == EPERM ? 0 : -1;
  }
  size_t total = sizeof(value.handle.handle_type) + value.handle.handle_bytes;
  if (total > capacity) {
    errno = EOVERFLOW;
    return -1;
  }
  memcpy(bytes, &value.handle.handle_type, sizeof(value.handle.handle_type));
  memcpy(bytes + sizeof(value.handle.handle_type), value.handle.f_handle, value.handle.handle_bytes);
  *count = total;
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
