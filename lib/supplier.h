// Seed-supplier files (--to / --from). Host-only; not part of the kernel.
//
// A supplier file is a sorted list of seed ranks (see seed_rank / s_from_rank)
// that passed some filter at some cutoff, so later searches can run over just
// those seeds instead of walking the whole pool again. Layout:
//
//   offset  size  field
//        0     8  magic "IMMSEEDS"
//        8     4  u32 format version (1)
//       12     4  u32 encoding (1 = delta-coded LEB128 varints)
//       16    64  filter name, NUL-padded
//       80     8  i64 cutoff the seeds were collected at
//       88     8  i64 start rank of the range that was walked
//       96     8  i64 number of seeds in that range
//      104     4  u32 flags: bit 0 set once the file was closed cleanly;
//                 bit 1 set if the seeds were drawn from another supplier file (--from)
//      108     8  u64 count of ranks in the body (written when the file closes)
//      116        body
//
// The body is the ranks in ascending order, each stored as the LEB128 varint of
// its difference from the previous rank; the first is stored as rank + 1 (from a
// notional previous rank of -1), so the empty seed, rank 0, is representable.
// Ranks are unique, so every delta is >= 1. Seeds that pass a filter at a few
// percent are spaced ~25-30 apart on average, which codes in one byte instead
// of eight.
// Everything is little-endian; the fields are written and read bytewise so the
// file is portable between hosts.
#ifndef IMMOLATE_SUPPLIER_H
#define IMMOLATE_SUPPLIER_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef _WIN32
    #define sup_fseek64 _fseeki64
    #define sup_ftell64 _ftelli64
#else
    #define sup_fseek64 fseeko
    #define sup_ftell64 ftello
#endif

#define SUP_MAGIC "IMMSEEDS"
#define SUP_VERSION 1u
#define SUP_ENC_DELTA_VARINT 1u
#define SUP_HEADER_SIZE 116
#define SUP_FLAGS_OFFSET 104
#define SUP_COUNT_OFFSET 108
#define SUP_FLAG_CLOSED 1u
#define SUP_FLAG_FROM_FILE 2u

typedef struct SupplierHeader {
    uint32_t version;
    uint32_t encoding;
    char filter[64];
    int64_t cutoff;
    int64_t start_rank;
    int64_t num_seeds;
    uint32_t flags;
    uint64_t count;
} sup_header;

static void sup_put_u32(unsigned char* p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (unsigned char)(v >> (8 * i)); }
static void sup_put_u64(unsigned char* p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (unsigned char)(v >> (8 * i)); }
static uint32_t sup_get_u32(const unsigned char* p) { uint32_t v = 0; for (int i = 3; i >= 0; i--) v = (v << 8) | p[i]; return v; }
static uint64_t sup_get_u64(const unsigned char* p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = (v << 8) | p[i]; return v; }

static void sup_encode_header(unsigned char out[SUP_HEADER_SIZE], const sup_header* h) {
    memset(out, 0, SUP_HEADER_SIZE);
    memcpy(out, SUP_MAGIC, 8);
    sup_put_u32(out + 8, h->version);
    sup_put_u32(out + 12, h->encoding);
    strncpy((char*)out + 16, h->filter, 63);
    sup_put_u64(out + 80, (uint64_t)h->cutoff);
    sup_put_u64(out + 88, (uint64_t)h->start_rank);
    sup_put_u64(out + 96, (uint64_t)h->num_seeds);
    sup_put_u32(out + 104, h->flags);
    sup_put_u64(out + 108, h->count);
}
// Returns 0 on success, or a message describing why the header is invalid.
static const char* sup_decode_header(const unsigned char in[SUP_HEADER_SIZE], sup_header* h) {
    if (memcmp(in, SUP_MAGIC, 8) != 0) return "not a seed-supplier file (bad magic)";
    h->version = sup_get_u32(in + 8);
    h->encoding = sup_get_u32(in + 12);
    memcpy(h->filter, in + 16, 64);
    h->filter[63] = '\0';
    h->cutoff = (int64_t)sup_get_u64(in + 80);
    h->start_rank = (int64_t)sup_get_u64(in + 88);
    h->num_seeds = (int64_t)sup_get_u64(in + 96);
    h->flags = sup_get_u32(in + 104);
    h->count = sup_get_u64(in + 108);
    if (h->version != SUP_VERSION) return "unsupported seed-supplier file version";
    if (h->encoding != SUP_ENC_DELTA_VARINT) return "unsupported seed-supplier encoding";
    return NULL;
}

// ---------------------------------------------------------------- writer ----
typedef struct SupplierWriter {
    FILE* f;
    uint32_t flags;        // header flags other than CLOSED, preserved on close
    int64_t prev;          // last rank written; deltas are taken from it
    uint64_t count;
    unsigned char* enc;    // scratch for one batch's encoded bytes
    size_t enc_cap;
} sup_writer;

static int sup_cmp_long(const void* a, const void* b) {
    int64_t x = *(const int64_t*)a, y = *(const int64_t*)b;
    return (x > y) - (x < y);
}

// Opens `path` for writing and emits a header with count 0; the true count is
// patched in by sup_writer_close. Returns 0 on failure.
static int sup_writer_open(sup_writer* w, const char* path, const char* filter, int64_t cutoff, int64_t start_rank, int64_t num_seeds, uint32_t flags) {
    memset(w, 0, sizeof *w);
    w->f = fopen(path, "wb");
    if (!w->f) return 0;
    w->flags = flags & ~SUP_FLAG_CLOSED;
    sup_header h;
    memset(&h, 0, sizeof h);
    h.version = SUP_VERSION;
    h.encoding = SUP_ENC_DELTA_VARINT;
    h.flags = w->flags;
    strncpy(h.filter, filter, 63);
    h.cutoff = cutoff;
    h.start_rank = start_rank;
    h.num_seeds = num_seeds;
    unsigned char buf[SUP_HEADER_SIZE];
    sup_encode_header(buf, &h);
    if (fwrite(buf, 1, SUP_HEADER_SIZE, w->f) != SUP_HEADER_SIZE || fflush(w->f) != 0) { fclose(w->f); w->f = NULL; return 0; }
    w->prev = -1; // one below the lowest rank, so rank 0 (the empty seed) can be first
    return 1;
}

// Appends `n` ranks. They may arrive in any order (the GPU writes them in
// atomic order) but every rank must exceed everything already in the file,
// which holds when batches are walked in ascending rank order. Sorts in place.
// Returns 0 on I/O error or ordering violation.
static int sup_writer_append(sup_writer* w, int64_t* ranks, size_t n) {
    if (n == 0) return 1;
    qsort(ranks, n, sizeof ranks[0], sup_cmp_long);
    if (ranks[0] <= w->prev) {
        fprintf(stderr, "Seed-supplier file: rank %lld is not above the last written rank %lld; batches must be ascending.\n", (long long)ranks[0], (long long)w->prev);
        return 0;
    }
    size_t need = n * 10;
    if (w->enc_cap < need) {
        free(w->enc);
        w->enc = (unsigned char*)malloc(need);
        w->enc_cap = w->enc ? need : 0;
        if (!w->enc) return 0;
    }
    size_t len = 0;
    int64_t prev = w->prev;
    for (size_t i = 0; i < n; i++) {
        uint64_t d = (uint64_t)(ranks[i] - prev);
        prev = ranks[i];
        while (d >= 0x80) { w->enc[len++] = (unsigned char)(d | 0x80); d >>= 7; }
        w->enc[len++] = (unsigned char)d;
    }
    if (fwrite(w->enc, 1, len, w->f) != len) return 0;
    // Push every batch to the OS at once: a killed run then loses nothing and
    // leaves no partial record for --resume to trim.
    if (fflush(w->f) != 0) return 0;
    w->prev = prev;
    w->count += n;
    return 1;
}

// Patches the count into the header and closes the file. Returns 0 on failure.
static int sup_writer_close(sup_writer* w) {
    int ok = 1;
    if (w->f) {
        unsigned char c[12];
        sup_put_u32(c, w->flags | SUP_FLAG_CLOSED);
        sup_put_u64(c + 4, w->count);
        if (sup_fseek64(w->f, SUP_FLAGS_OFFSET, SEEK_SET) != 0 || fwrite(c, 1, 12, w->f) != 12) ok = 0;
        if (fclose(w->f) != 0) ok = 0;
        w->f = NULL;
    }
    free(w->enc);
    w->enc = NULL;
    return ok;
}

#ifdef _WIN32
    #include <io.h>
    #define sup_truncate(f, len) _chsize_s(_fileno(f), (long long)(len))
#else
    #include <unistd.h>
    #define sup_truncate(f, len) ftruncate(fileno(f), (off_t)(len))
#endif

// Reopens an existing supplier file for appending, for --resume. Reads the
// header into *h, scans the body to find the last complete rank (a killed
// process can leave a partial varint at the end; it is cut off) and positions
// the writer after it. *complete is set if the file was closed cleanly, in
// which case nothing should be appended. *last_rank is the last rank in the
// body, or -1 if it is empty. Returns 0 with a message on failure.
static const char* sup_writer_reopen(sup_writer* w, const char* path, sup_header* h, int64_t* last_rank, int* complete) {
    memset(w, 0, sizeof *w);
    FILE* f = fopen(path, "rb");
    if (!f) return "cannot open file";
    unsigned char buf[SUP_HEADER_SIZE];
    size_t got = fread(buf, 1, SUP_HEADER_SIZE, f);
    if (got == 0) {
        // A 0-byte part: the previous run created it and died before its header
        // reached the disk. Nothing in it; the caller starts this part afresh.
        fclose(f);
        memset(h, 0, sizeof *h);
        *last_rank = -1;
        *complete = 0;
        return "empty";
    }
    if (got != SUP_HEADER_SIZE) { fclose(f); return "file too short for a header"; }
    const char* err = sup_decode_header(buf, h);
    if (err) { fclose(f); return err; }
    w->flags = h->flags & ~SUP_FLAG_CLOSED;
    *complete = (h->flags & SUP_FLAG_CLOSED) || h->count > 0;
    // Scan the body varint by varint, read-only.
    int64_t prev = -1;
    uint64_t count = 0;
    int64_t good_end = SUP_HEADER_SIZE; // byte offset just after the last complete varint
    int64_t pos = SUP_HEADER_SIZE;
    uint64_t d = 0;
    int shift = 0;
    static unsigned char rb[1 << 20];
    size_t n;
    while ((n = fread(rb, 1, sizeof rb, f)) > 0) {
        for (size_t i = 0; i < n; i++) {
            unsigned char b = rb[i];
            pos++;
            d |= (uint64_t)(b & 0x7f) << shift;
            shift += 7;
            if (!(b & 0x80)) {
                prev += (int64_t)d;
                count++;
                good_end = pos;
                d = 0;
                shift = 0;
            } else if (shift >= 64) {
                fclose(f); return "corrupt varint in body";
            }
        }
    }
    fclose(f);
    if (*complete && h->count != count) {
        fprintf(stderr, "%s says %llu ranks but holds %llu; treating it as incomplete.\n", path, (unsigned long long)h->count, (unsigned long long)count);
        *complete = 0;
    }
    // Reopen for update and position after the last complete record. Truncate
    // first through a fresh handle so no stale read buffer is in play.
    w->f = fopen(path, "r+b");
    if (!w->f) return "cannot open file for update";
    if (pos != good_end) {
        fprintf(stderr, "Dropping %lld trailing bytes of an incomplete record from %s.\n", (long long)(pos - good_end), path);
        if (sup_truncate(w->f, good_end) != 0) { fclose(w->f); w->f = NULL; return "cannot truncate partial record"; }
    }
    if (sup_fseek64(w->f, good_end, SEEK_SET) != 0) { fclose(w->f); w->f = NULL; return "cannot seek"; }
    w->prev = prev;
    w->count = count;
    *last_rank = count ? prev : -1;
    return NULL;
}

// ---------------------------------------------------------------- reader ----
#define SUP_READ_BUF (1 << 20)
typedef struct SupplierReader {
    FILE* f;
    sup_header header;
    int64_t prev;
    uint64_t consumed;     // ranks decoded so far
    unsigned char* buf;
    size_t buf_len, buf_pos;
    int eof;
    int has_pending;       // one rank held back by sup_reader_skip_through
    int64_t pending;
} sup_reader;

// Opens and validates `path`. On failure returns a message and leaves r unusable.
static const char* sup_reader_open(sup_reader* r, const char* path) {
    memset(r, 0, sizeof *r);
    r->f = fopen(path, "rb");
    if (!r->f) return "cannot open file";
    unsigned char buf[SUP_HEADER_SIZE];
    if (fread(buf, 1, SUP_HEADER_SIZE, r->f) != SUP_HEADER_SIZE) { fclose(r->f); r->f = NULL; return "file too short for a header"; }
    const char* err = sup_decode_header(buf, &r->header);
    if (err) { fclose(r->f); r->f = NULL; return err; }
    r->buf = (unsigned char*)malloc(SUP_READ_BUF);
    if (!r->buf) { fclose(r->f); r->f = NULL; return "out of memory"; }
    r->prev = -1; // matches the writer: the first delta is rank + 1
    return NULL;
}

static int sup_reader_byte(sup_reader* r) {
    if (r->buf_pos >= r->buf_len) {
        if (r->eof) return -1;
        r->buf_len = fread(r->buf, 1, SUP_READ_BUF, r->f);
        r->buf_pos = 0;
        if (r->buf_len == 0) { r->eof = 1; return -1; }
    }
    return r->buf[r->buf_pos++];
}

// Decodes up to `max` ranks into `out`. Returns how many were decoded; 0 means
// the file is exhausted. Stops at the header's count so trailing garbage is
// ignored; a truncated body ends early with a warning.
static size_t sup_reader_next(sup_reader* r, int64_t* out, size_t max) {
    size_t n = 0;
    if (max > 0 && r->has_pending) {
        out[n++] = r->pending;
        r->has_pending = 0;
    }
    while (n < max && r->consumed < r->header.count) {
        uint64_t d = 0;
        int shift = 0, b;
        do {
            b = sup_reader_byte(r);
            if (b < 0) {
                if (n == 0 || shift > 0) fprintf(stderr, "Seed-supplier file ends after %llu of %llu ranks.\n", (unsigned long long)r->consumed, (unsigned long long)r->header.count);
                r->header.count = r->consumed; // stop for good
                return n;
            }
            d |= (uint64_t)(b & 0x7f) << shift;
            shift += 7;
        } while ((b & 0x80) && shift < 64);
        r->prev += (int64_t)d;
        out[n++] = r->prev;
        r->consumed++;
    }
    return n;
}

// Skips every rank <= last_rank (the file is sorted). Returns how many were
// skipped. The first rank above last_rank is held back and returned by the next
// sup_reader_next call.
static inline uint64_t sup_reader_skip_through(sup_reader* r, int64_t last_rank) {
    uint64_t skipped = 0;
    int64_t v;
    while (sup_reader_next(r, &v, 1) == 1) {
        if (v > last_rank) {
            r->has_pending = 1;
            r->pending = v;
            break;
        }
        skipped++;
    }
    return skipped;
}

static void sup_reader_close(sup_reader* r) {
    if (r->f) fclose(r->f);
    free(r->buf);
    r->f = NULL;
    r->buf = NULL;
}

// ----------------------------------------------------------- multi-reader ----
// Reads several supplier files as one ascending stream: the completed parts of
// a --to_parts run, or any explicit list. Files are read in the order given;
// parts of one run are ascending and contiguous, so their concatenation is
// sorted. The aggregate header takes filter, cutoff, range and flags from the
// first file and sums the counts.
#define SUP_MAX_FILES 4096
typedef struct SupplierMulti {
    char** paths;
    int num_paths;
    int cur;               // index of the file currently open, or num_paths when done
    sup_reader r;
    int r_open;
    sup_header header;     // aggregate
    int has_pending;
    int64_t pending;
} sup_multi;

// Header-only peek. Returns NULL and fills *h on success, else a message.
static const char* sup_peek_header(const char* path, sup_header* h) {
    FILE* f = fopen(path, "rb");
    if (!f) return "cannot open file";
    unsigned char buf[SUP_HEADER_SIZE];
    size_t got = fread(buf, 1, SUP_HEADER_SIZE, f);
    fclose(f);
    if (got != SUP_HEADER_SIZE) return "file too short for a header";
    return sup_decode_header(buf, h);
}
// A file is complete when it was closed cleanly, or (files from before the
// flag existed) when its count was patched in.
static int sup_header_complete(const sup_header* h) {
    return (h->flags & SUP_FLAG_CLOSED) || h->count > 0;
}

#ifdef _WIN32
    #include <windows.h>
#else
    #include <dirent.h>
#endif
// Finds the part files of `base` (base.part<k>of<K>) in its directory. Fills
// out_paths (malloc'd strings) in ascending k, returns the number found, and
// sets *K. Returns 0 if there are none; -1 if parts of different K coexist.
static int sup_discover_parts(const char* base, char** out_paths, int max, int* K) {
    // Split into directory and file name.
    const char* slash = strrchr(base, '/');
#ifdef _WIN32
    const char* bslash = strrchr(base, '\\');
    if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
    char dir[2048];
    const char* name = base;
    if (slash) {
        size_t n = (size_t)(slash - base);
        if (n >= sizeof dir - 1) return 0;
        memcpy(dir, base, n); dir[n] = '\0';
        name = slash + 1;
    } else {
        strcpy(dir, ".");
    }
    size_t nlen = strlen(name);
    int found = 0, k_of[SUP_MAX_FILES], kk = 0;
    char* tmp_paths[SUP_MAX_FILES];
    int tmp_k[SUP_MAX_FILES];
#ifdef _WIN32
    char pattern[2304];
    snprintf(pattern, sizeof pattern, "%s\\%s.part*of*", dir, name);
    WIN32_FIND_DATAA fd;
    HANDLE hf = FindFirstFileA(pattern, &fd);
    if (hf == INVALID_HANDLE_VALUE) return 0;
    do {
        const char* fn = fd.cFileName;
#else
    DIR* d = opendir(dir);
    if (!d) return 0;
    struct dirent* de;
    while ((de = readdir(d)) != NULL) {
        const char* fn = de->d_name;
#endif
        if (strncmp(fn, name, nlen) == 0 && strncmp(fn + nlen, ".part", 5) == 0) {
            int p = 0, q = 0, used = 0;
            if (sscanf(fn + nlen + 5, "%dof%d%n", &p, &q, &used) == 2 && fn[nlen + 5 + used] == '\0' && p >= 1 && q >= p && found < SUP_MAX_FILES) {
                if (kk == 0) kk = q;
                if (q != kk) { found = -1; break; }
                size_t plen = strlen(dir) + 1 + strlen(fn) + 1;
                tmp_paths[found] = (char*)malloc(plen);
                if (slash) snprintf(tmp_paths[found], plen, "%s%c%s", dir, slash[0], fn);
                else snprintf(tmp_paths[found], plen, "%s", fn);
                tmp_k[found] = p;
                found++;
            }
        }
#ifdef _WIN32
    } while (FindNextFileA(hf, &fd));
    FindClose(hf);
#else
    }
    closedir(d);
#endif
    if (found <= 0) return found;
    // Insertion sort by k (few files).
    for (int i = 1; i < found; i++) {
        char* pp = tmp_paths[i]; int pk = tmp_k[i]; int j = i - 1;
        while (j >= 0 && tmp_k[j] > pk) { tmp_paths[j + 1] = tmp_paths[j]; tmp_k[j + 1] = tmp_k[j]; j--; }
        tmp_paths[j + 1] = pp; tmp_k[j + 1] = pk;
    }
    int n = found < max ? found : max;
    for (int i = 0; i < n; i++) { out_paths[i] = tmp_paths[i]; k_of[i] = tmp_k[i]; }
    for (int i = n; i < found; i++) free(tmp_paths[i]);
    (void)k_of;
    *K = kk;
    return n;
}

// Opens a list of files. Each is validated; incomplete ones (still being
// written, or truncated) are skipped with a message. Returns NULL on success.
static const char* sup_multi_open(sup_multi* m, char** paths, int num) {
    memset(m, 0, sizeof *m);
    m->paths = (char**)malloc(sizeof(char*) * (size_t)(num > 0 ? num : 1));
    int kept = 0;
    for (int i = 0; i < num; i++) {
        sup_header h;
        const char* err = sup_peek_header(paths[i], &h);
        if (err) { fprintf(stderr, "Skipping %s: %s.\n", paths[i], err); continue; }
        if (!sup_header_complete(&h)) { fprintf(stderr, "Skipping %s: not finished (still being written, or interrupted; --resume it first).\n", paths[i]); continue; }
        if (kept == 0) { m->header = h; }
        else {
            m->header.count += h.count;
            if (strcmp(h.filter, m->header.filter) != 0 || h.cutoff != m->header.cutoff)
                fprintf(stderr, "Note: %s was made with filter %s at cutoff %lld, unlike the first file.\n", paths[i], h.filter, (long long)h.cutoff);
        }
        m->paths[kept++] = paths[i];
    }
    m->num_paths = kept;
    if (kept == 0) return "no complete seed-supplier files";
    m->cur = -1;
    return NULL;
}

// Moves to the next file. Returns 0 when there are none left.
static int sup_multi_advance(sup_multi* m) {
    if (m->r_open) { sup_reader_close(&m->r); m->r_open = 0; }
    while (++m->cur < m->num_paths) {
        const char* err = sup_reader_open(&m->r, m->paths[m->cur]);
        if (err) { fprintf(stderr, "Skipping %s: %s.\n", m->paths[m->cur], err); continue; }
        m->r_open = 1;
        return 1;
    }
    return 0;
}

static size_t sup_multi_next(sup_multi* m, int64_t* out, size_t max) {
    size_t n = 0;
    if (max > 0 && m->has_pending) { out[n++] = m->pending; m->has_pending = 0; }
    while (n < max) {
        if (!m->r_open && !sup_multi_advance(m)) break;
        size_t got = sup_reader_next(&m->r, out + n, max - n);
        n += got;
        if (got == 0) { sup_reader_close(&m->r); m->r_open = 0; }
    }
    return n;
}

static uint64_t sup_multi_skip_through(sup_multi* m, int64_t last_rank) {
    uint64_t skipped = 0;
    int64_t v;
    while (sup_multi_next(m, &v, 1) == 1) {
        if (v > last_rank) { m->has_pending = 1; m->pending = v; break; }
        skipped++;
    }
    return skipped;
}

static void sup_multi_close(sup_multi* m) {
    if (m->r_open) sup_reader_close(&m->r);
    m->r_open = 0;
    free(m->paths);
    m->paths = NULL;
}

#endif
