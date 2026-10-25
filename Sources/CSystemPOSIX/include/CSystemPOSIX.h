#ifndef COMPUTER_MCP_SYSTEM_POSIX_H
#define COMPUTER_MCP_SYSTEM_POSIX_H

#if defined(__linux__)
#include <spawn.h>
#include <stdint.h>
#include <sys/types.h>

int computer_mcp_renameat_noreplace(int source, const char *name, int target, const char *leaf);
int computer_mcp_spawn_addfchdir(posix_spawn_file_actions_t *actions, int descriptor);
int computer_mcp_openat_identity(int parent, const char *name);
int computer_mcp_birthtime(int descriptor, int64_t *seconds, int64_t *nanoseconds);
int computer_mcp_chmod_identity(int descriptor, mode_t mode);
ssize_t computer_mcp_flistxattr(int descriptor, char *names, size_t size);
ssize_t computer_mcp_fgetxattr(int descriptor, const char *name, void *value, size_t size);
int computer_mcp_fsetxattr(int descriptor, const char *name, const void *value, size_t size);
int computer_mcp_fremovexattr(int descriptor, const char *name);
#endif

#endif
