// Filters normally define `long filter(instance* inst)`. A filter that wants
// the -c cutoff (to stop early once a seed has passed it, or can no longer
// reach it) defines FILTER_USES_CUTOFF and takes it as a second argument:
//     #define FILTER_USES_CUTOFF
//     long filter(instance* inst, long cutoff) { ... }
// The value is the run's -c, unchanged; passing it costs nothing measurable.
#ifdef FILTER_USES_CUTOFF
#define RUN_FILTER(inst_ptr) filter(inst_ptr, filter_cutoff)
#else
#define RUN_FILTER(inst_ptr) filter(inst_ptr)
#endif

// Single-pass search: every seed in [start_rank, start_rank + num_seeds) runs
// the filter and is printed if its score reaches the -c cutoff. Each lane
// derives its first seed from its rank once, then steps by the stride.
__kernel void search(long start_rank, long num_seeds, long filter_cutoff) {
    long i = get_global_id(0);
    if (i >= num_seeds) return;
    long stride = get_global_size(0);
    seed _seed = s_from_rank(start_rank + i);
    for (; i < num_seeds; i += stride) {
        instance inst;
        i_init(&inst, _seed);
        long score = RUN_FILTER(&inst);
        // The cutoff is the value given with -c and never changes during a run.
        if (score >= filter_cutoff) {
            s_print_score(&_seed, score);
        }
        s_skip(&_seed, stride);
    }
}

// Rank-list search: the same as `search`, but the seeds come from a packed
// list of ranks (a two-pass prefilter's survivors, or a supplier file given
// with --from) instead of a contiguous range.
__kernel void search_ranks(__global const long* ranks, long num_ranks, long filter_cutoff) {
    for (long i = get_global_id(0); i < num_ranks; i += get_global_size(0)) {
        seed _seed = s_from_rank(ranks[i]);
        instance inst;
        i_init(&inst, _seed);
        long score = RUN_FILTER(&inst);
        if (score >= filter_cutoff) {
            s_print_score(&_seed, score);
        }
    }
}

// ---------------------------------------------------------------------------
// Collecting kernels. Instead of printing, these append the rank of every
// passing seed to `out`, so the host can read the list back and either run a
// second pass on it or write it to a supplier file (--to). All three share one
// aggregation scheme: each lane keeps up to COLLECT_CHUNK hits in registers,
// the work-group sums its hits through local memory, and one lane does a single
// global atomic per group per round instead of one contended atomic per hit.
// `out` is sized by the host to hold every seed of the batch, so it can never
// overflow whatever the pass rate.
#ifndef COLLECT_CHUNK
#define COLLECT_CHUNK 8
#endif
#ifdef PREFILTER_CHUNK
#undef COLLECT_CHUNK
#define COLLECT_CHUNK PREFILTER_CHUNK // older name, honoured for existing filters
#endif

// Flush this lane's `n` hits. Every lane in the group must call this the same
// number of times so the barriers line up; lanes with nothing pass n = 0.
inline void collect_flush(long mine[], int n, __global long* out, volatile __global uint* out_count,
                          __local uint* group_base, __local uint* group_count) {
    if (get_local_id(0) == 0) *group_count = 0;
    barrier(CLK_LOCAL_MEM_FENCE);
    uint my_off = n ? atomic_add(group_count, (uint)n) : 0;
    barrier(CLK_LOCAL_MEM_FENCE);
    if (get_local_id(0) == 0) *group_base = *group_count ? atomic_add(out_count, *group_count) : 0;
    barrier(CLK_LOCAL_MEM_FENCE);
    for (int k = 0; k < n; k++) out[*group_base + my_off + k] = mine[k];
}

// Walk a rank range and collect every seed for which PRED holds. The body is
// a macro rather than a function taking a predicate pointer because OpenCL C
// has no function pointers.
#define COLLECT_RANGE_BODY(PRED)                                                        \
    __local uint group_base;                                                            \
    __local uint group_count;                                                           \
    long gsize = get_global_size(0);                                                    \
    long i = get_global_id(0);                                                          \
    seed _seed = s_from_rank(start_rank + (i < num_seeds ? i : 0));                     \
    long mine[COLLECT_CHUNK];                                                           \
    long rounds = (num_seeds + gsize * COLLECT_CHUNK - 1) / (gsize * COLLECT_CHUNK);    \
    for (long r = 0; r < rounds; r++) {                                                 \
        int n = 0;                                                                      \
        for (int k = 0; k < COLLECT_CHUNK; k++) {                                       \
            if (i < num_seeds) {                                                        \
                instance inst;                                                          \
                i_init(&inst, _seed);                                                   \
                if (PRED) mine[n++] = start_rank + i;                                   \
                s_skip(&_seed, gsize);                                                  \
                i += gsize;                                                             \
            }                                                                           \
        }                                                                               \
        collect_flush(mine, n, out, out_count, &group_base, &group_count);              \
    }

// Full filter over a rank range, collecting seeds whose score reaches the cutoff.
__kernel void search_collect(long start_rank, long num_seeds, long filter_cutoff,
                             __global long* out, volatile __global uint* out_count) {
    COLLECT_RANGE_BODY(RUN_FILTER(&inst) >= filter_cutoff)
}

// Full filter over a packed rank list, collecting seeds whose score reaches the
// cutoff. Used for pass 2 of a two-pass search and for --from when --to is set.
__kernel void search_ranks_collect(__global const long* ranks, long num_ranks, long filter_cutoff,
                                   __global long* out, volatile __global uint* out_count) {
    __local uint group_base;
    __local uint group_count;
    long gsize = get_global_size(0);
    long i = get_global_id(0);
    long mine[COLLECT_CHUNK];
    long rounds = (num_ranks + gsize * COLLECT_CHUNK - 1) / (gsize * COLLECT_CHUNK);
    for (long r = 0; r < rounds; r++) {
        int n = 0;
        for (int k = 0; k < COLLECT_CHUNK; k++) {
            if (i < num_ranks) {
                seed _seed = s_from_rank(ranks[i]);
                instance inst;
                i_init(&inst, _seed);
                if (RUN_FILTER(&inst) >= filter_cutoff) mine[n++] = ranks[i];
                i += gsize;
            }
        }
        collect_flush(mine, n, out, out_count, &group_base, &group_count);
    }
}

// Two-pass search, used when the filter defines HAS_PREFILTER and
//     bool prefilter(instance* inst)
// which must return true for every seed whose filter() score could reach the
// cutoff (false positives are fine, false negatives lose seeds). Pass 1 runs
// only the prefilter on every seed and records survivors' ranks. Pass 2 runs
// the full filter on the survivors, packed contiguously, so every lane in a
// warp is doing the same expensive work instead of idling behind one deep seed.
#ifdef HAS_PREFILTER
__kernel void search_prefilter(long start_rank, long num_seeds,
                               __global long* out, volatile __global uint* out_count) {
    COLLECT_RANGE_BODY(prefilter(&inst))
}
#endif
