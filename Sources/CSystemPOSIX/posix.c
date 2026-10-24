#if defined(__linux__)
// GNU declarations must be enabled before any libc header is parsed.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "CSystemPOSIX.h"
#include <stdio.h>
#include <sys/xattr.h>

int computer_mcp_renameat_noreplace(int source, const char *name, int target, const char *leaf) {
  return renameat2(source, name, target, leaf, RENAME_NOREPLACE);
}

int computer_mcp_spawn_addfchdir(posix_spawn_file_actions_t *actions, int descriptor) {
  return posix_spawn_file_actions_addfchdir_np(actions, descriptor);
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
