// The parts of libarchive FileCat uses. libarchive ships with iOS (/usr/lib/libarchive.2.dylib)
// but the SDK has no header for it, so the declarations are repeated here. They match
// libarchive 3.x's archive.h and archive_entry.h.

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF       1
#define ARCHIVE_OK        0
#define ARCHIVE_RETRY   (-10)
#define ARCHIVE_WARN    (-20)
#define ARCHIVE_FAILED  (-25)
#define ARCHIVE_FATAL   (-30)

#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_RAW       0x90000

#define AE_IFMT   0170000
#define AE_IFREG  0100000
#define AE_IFLNK  0120000
#define AE_IFDIR  0040000

// Reading
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_cab(struct archive *);
int archive_read_support_format_cpio(struct archive *);
int archive_read_support_format_iso9660(struct archive *);
int archive_read_support_format_lha(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_xar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t size);
int archive_read_data_skip(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int archive_read_free(struct archive *);

// Errors and formats
const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);
int archive_format(struct archive *);

// Entries
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_is_data_encrypted(struct archive_entry *);
void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
void archive_entry_set_mtime(struct archive_entry *, time_t, long);

// Writing
struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_set_format_7zip(struct archive *);
int archive_write_set_format_pax_restricted(struct archive *);
int archive_write_add_filter_gzip(struct archive *);
int archive_write_set_options(struct archive *, const char *options);
int archive_write_open_filename(struct archive *, const char *filename);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *buffer, size_t size);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);
