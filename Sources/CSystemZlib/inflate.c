#include "CSystemZlib.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

int cmcp_inflate_bounded(const uint8_t *input, size_t length, size_t limit,
                         uint8_t *prefix, size_t prefix_capacity,
                         size_t *consumed, size_t *produced) {
    z_stream stream = {0};
    uint8_t output[32768];
    size_t supplied = 0, copied = 0, total = 0;
    *consumed = 0;
    *produced = 0;
    if (inflateInit(&stream) != Z_OK) return -1;
    int result = -1;
    for (;;) {
        if (stream.avail_in == 0 && supplied < length) {
            size_t n = length - supplied;
            if (n > UINT_MAX) n = UINT_MAX;
            stream.next_in = (Bytef *)(input + supplied);
            stream.avail_in = (uInt)n;
            supplied += n;
        }
        stream.next_out = output;
        stream.avail_out = sizeof(output);
        int status = inflate(&stream, Z_NO_FLUSH);
        size_t n = sizeof(output) - stream.avail_out;
        if (n > limit - total) break;
        total += n;
        size_t keep = prefix_capacity - copied;
        if (keep > n) keep = n;
        if (keep) memcpy(prefix + copied, output, keep);
        copied += keep;
        if (status == Z_STREAM_END) { result = 0; break; }
        if (status != Z_OK || (!n && !stream.avail_in && supplied == length)) break;
    }
    *consumed = supplied - stream.avail_in;
    *produced = total;
    inflateEnd(&stream);
    return result;
}
