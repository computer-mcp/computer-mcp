#ifndef COMPUTER_MCP_SYSTEM_ZLIB_H
#define COMPUTER_MCP_SYSTEM_ZLIB_H
#include <stddef.h>
#include <stdint.h>
/* Inflate one zlib stream with fixed memory and an output ceiling. Returns 0
 * only at stream end; trailing input is reported through consumed, not read. */
int cmcp_inflate_bounded(const uint8_t *input, size_t length, size_t limit,
                         uint8_t *prefix, size_t prefix_capacity,
                         size_t *consumed, size_t *produced);
#endif
