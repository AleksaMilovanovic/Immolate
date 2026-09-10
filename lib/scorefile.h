// Exact score-stream files (--scores_to). Host-only; not part of the kernel.
//
// Layout:
//
//   offset  size  field
//        0     8  magic "IMMSCORE"
//        8     4  u32 format version (1)
//       12     4  u32 flags: bit 0 set once the file was closed cleanly
//       16    64  filter name, NUL-padded
//       80     8  i64 start rank
//       88     8  u64 number of scores in the body
//       96        body: consecutive signed i64 scores
//
// Everything is little-endian and encoded bytewise so files are portable.
#ifndef IMMOLATE_SCOREFILE_H
#define IMMOLATE_SCOREFILE_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
    #define score_fseek64 _fseeki64
    #define score_ftell64 _ftelli64
#else
    #define score_fseek64 fseeko
    #define score_ftell64 ftello
#endif

#define SCORE_MAGIC "IMMSCORE"
#define SCORE_VERSION 1u
#define SCORE_HEADER_SIZE 96
#define SCORE_FLAGS_OFFSET 12
#define SCORE_COUNT_OFFSET 88
#define SCORE_FLAG_CLOSED 1u

typedef struct ScoreWriter {
    FILE* f;
    uint64_t count;
    unsigned char* enc;
    size_t enc_cap;
} score_writer;

static void score_put_u32(unsigned char* p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (unsigned char)(v >> (8 * i));
}

static void score_put_u64(unsigned char* p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (unsigned char)(v >> (8 * i));
}

// Opens `path` for writing and emits an incomplete header. The CLOSED flag and
// true count are patched only by score_writer_close. Returns 0 on failure.
static int score_writer_open(score_writer* w, const char* path, const char* filter, int64_t start_rank) {
    if (!w || !path || !filter) return 0;
    memset(w, 0, sizeof *w);
    w->f = fopen(path, "wb");
    if (!w->f) return 0;

    unsigned char header[SCORE_HEADER_SIZE];
    memset(header, 0, sizeof header);
    memcpy(header, SCORE_MAGIC, 8);
    score_put_u32(header + 8, SCORE_VERSION);
    score_put_u32(header + SCORE_FLAGS_OFFSET, 0);
    strncpy((char*)header + 16, filter, 63);
    score_put_u64(header + 80, (uint64_t)start_rank);
    score_put_u64(header + SCORE_COUNT_OFFSET, 0);
    if (fwrite(header, 1, sizeof header, w->f) != sizeof header || fflush(w->f) != 0) {
        fclose(w->f);
        w->f = NULL;
        return 0;
    }
    return 1;
}

// Appends `n` scores in their existing order. Returns 0 on allocation, count,
// or I/O failure. The header remains incomplete until score_writer_close.
static int score_writer_append(score_writer* w, const int64_t* scores, size_t n) {
    if (!w || !w->f || (!scores && n != 0)) return 0;
    if (n == 0) return 1;
    if (n > SIZE_MAX / 8 || w->count > UINT64_MAX - (uint64_t)n) return 0;

    size_t need = n * 8;
    if (w->enc_cap < need) {
        unsigned char* enc = (unsigned char*)realloc(w->enc, need);
        if (!enc) return 0;
        w->enc = enc;
        w->enc_cap = need;
    }
    for (size_t i = 0; i < n; i++) {
        score_put_u64(w->enc + i * 8, (uint64_t)scores[i]);
    }
    if (fwrite(w->enc, 1, need, w->f) != need || fflush(w->f) != 0) return 0;
    w->count += (uint64_t)n;
    return 1;
}

// Closes without setting CLOSED. Used after any host or OpenCL error so a
// decoder can distinguish the partial stream. Returns 0 if closing failed.
static int score_writer_abort(score_writer* w) {
    if (!w) return 0;
    int ok = 1;
    if (w->f && fclose(w->f) != 0) ok = 0;
    w->f = NULL;
    free(w->enc);
    w->enc = NULL;
    w->enc_cap = 0;
    return ok;
}

// Patches count first and CLOSED last, then closes. If patching fails before
// CLOSED is written, the file remains explicitly incomplete. Returns 0 on any
// seek, write, flush, or close failure.
static int score_writer_close(score_writer* w) {
    if (!w) return 0;
    int ok = 1;
    if (w->f) {
        unsigned char count[8];
        unsigned char flags[4];
        score_put_u64(count, w->count);
        score_put_u32(flags, SCORE_FLAG_CLOSED);
        if (score_fseek64(w->f, SCORE_COUNT_OFFSET, SEEK_SET) != 0 ||
            fwrite(count, 1, sizeof count, w->f) != sizeof count ||
            fflush(w->f) != 0) {
            ok = 0;
        }
        if (ok && (score_fseek64(w->f, SCORE_FLAGS_OFFSET, SEEK_SET) != 0 ||
                   fwrite(flags, 1, sizeof flags, w->f) != sizeof flags ||
                   fflush(w->f) != 0)) {
            ok = 0;
        }
        if (fclose(w->f) != 0) ok = 0;
        w->f = NULL;
    }
    free(w->enc);
    w->enc = NULL;
    w->enc_cap = 0;
    return ok;
}

#endif
