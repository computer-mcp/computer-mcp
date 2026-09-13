#ifndef COMPUTER_MCP_SYSTEM_ARCHIVE_H
#define COMPUTER_MCP_SYSTEM_ARCHIVE_H

#include <stdint.h>
#include <sys/types.h>

// Minimal macOS libarchive ABI declarations. The SDK supplies libarchive.2.tbd
// but not the headers. No parser implementation or external binary is bundled.
struct archive;
struct archive_entry;

struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
int archive_filter_count(struct archive *);
int archive_filter_code(struct archive *, int);
int64_t archive_filter_bytes(struct archive *, int);

const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_sparse_count(struct archive_entry *);

#endif
