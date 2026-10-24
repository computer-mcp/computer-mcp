#ifndef COMPUTER_MCP_SYSTEM_POSIX_H
#define COMPUTER_MCP_SYSTEM_POSIX_H

#if defined(__linux__)
#include <spawn.h>
#include <sys/types.h>

int computer_mcp_renameat_noreplace(int source, const char *name, int target, const char *leaf);
int computer_mcp_spawn_addfchdir(posix_spawn_file_actions_t *actions, int descriptor);
ssize_t computer_mcp_flistxattr(int descriptor, char *names, size_t size);
ssize_t computer_mcp_fgetxattr(int descriptor, const char *name, void *value, size_t size);
int computer_mcp_fsetxattr(int descriptor, const char *name, const void *value, size_t size);
int computer_mcp_fremovexattr(int descriptor, const char *name);
#endif

#endif
