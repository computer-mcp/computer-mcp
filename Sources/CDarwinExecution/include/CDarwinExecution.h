#ifndef COMPUTER_MCP_DARWIN_EXECUTION_H
#define COMPUTER_MCP_DARWIN_EXECUTION_H
#include <sys/types.h>

/* Returns -1 if the sandbox query SPI is unavailable. */
int execution_sandbox_check(pid_t pid, const char *path);
#endif
