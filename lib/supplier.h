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
//      104     4  u32 reserved (0)
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
#define SUP_COUNT_OFFSET 108

typedef struct SupplierHeader {
    uint32_t version;
    uint32_t encoding;
    char filter[64];
    int64_t cutoff;
    int64_t start_rank;
    int64_t num_seeds;
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
    sup_put_u32(out + 104, 0);
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
    h->count = sup_get_u64(in + 108);
    if (h->version != SUP_VERSION) return "unsupported seed-supplier file version";
    if (h->encoding != SUP_ENC_DELTA_VARINT) return "unsupported seed-supplier encoding";
    return NULL;
}

// ---------------------------------------------------------------- writer ----
typedef struct SupplierWriter {
    FILE* f;
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
static int sup_writer_open(sup_writer* w, const char* path, const char* filter, int64_t cutoff, int64_t start_rank, int64_t num_seeds) {
    memset(w, 0, sizeof *w);
    w->f = fopen(path, "wb");
    if (!w->f) return 0;
    sup_header h;
    memset(&h, 0, sizeof h);
    h.version = SUP_VERSION;
    h.encoding = SUP_ENC_DELTA_VARINT;
    strncpy(h.filter, filter, 63);
    h.cutoff = cutoff;
    h.start_rank = start_rank;
    h.num_seeds = num_seeds;
    unsigned char buf[SUP_HEADER_SIZE];
    sup_encode_header(buf, &h);
    if (fwrite(buf, 1, SUP_HEADER_SIZE, w->f) != SUP_HEADER_SIZE) { fclose(w->f); w->f = NULL; return 0; }
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
    w->prev = prev;
    w->count += n;
    return 1;
}

// Patches the count into the header and closes the file. Returns 0 on failure.
static int sup_writer_close(sup_writer* w) {
    int ok = 1;
    if (w->f) {
        unsigned char c[8];
        sup_put_u64(c, w->count);
        if (sup_fseek64(w->f, SUP_COUNT_OFFSET, SEEK_SET) != 0 || fwrite(c, 1, 8, w->f) != 8) ok = 0;
        if (fclose(w->f) != 0) ok = 0;
        w->f = NULL;
    }
    free(w->enc);
    w->enc = NULL;
    return ok;
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

static void sup_reader_close(sup_reader* r) {
    if (r->f) fclose(r->f);
    free(r->buf);
    r->f = NULL;
    r->buf = NULL;
}

#endif
