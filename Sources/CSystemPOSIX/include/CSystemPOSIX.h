#ifndef COMPUTER_MCP_SYSTEM_POSIX_H
#define COMPUTER_MCP_SYSTEM_POSIX_H

#if defined(__linux__)
#include <spawn.h>
#include <stdint.h>
#include <sys/types.h>

int computer_mcp_renameat_noreplace(int source, const char *name, int target, const char *leaf);
int computer_mcp_spawn_addfchdir(posix_spawn_file_actions_t *actions, int descriptor);
int computer_mcp_openat_identity(int parent, const char *name);
// Holds a handle type and MAX_HANDLE_SZ (128) handle bytes.
#define COMPUTER_MCP_FILE_HANDLE_CAPACITY 132
int computer_mcp_file_handle(int descriptor, unsigned char *bytes, size_t capacity, size_t *count);
int computer_mcp_chmod_identity(int descriptor, mode_t mode);
ssize_t computer_mcp_flistxattr(int descriptor, char *names, size_t size);
ssize_t computer_mcp_fgetxattr(int descriptor, const char *name, void *value, size_t size);
int computer_mcp_fsetxattr(int descriptor, const char *name, const void *value, size_t size);
int computer_mcp_fremovexattr(int descriptor, const char *name);
#endif

#endif
