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

// Temporary benchmark fixtures can define this to compile the previous range
// walker from the same checkout. Normal filters derive each iteration's seed
// directly from its rank, avoiding s_tell() inside s_skip().
#ifdef SEARCH_LEGACY_RANGE_SEED_STEPPING
#define RANGE_SEED_STATE(name, rank) seed name = s_from_rank(rank)
#define RANGE_SEED_LOAD(name, rank) ((void)0)
#define RANGE_SEED_ADVANCE(name, stride) s_skip(&(name), stride)
#else
#define RANGE_SEED_STATE(name, rank) ((void)0)
#define RANGE_SEED_LOAD(name, rank) seed name = s_from_rank(rank)
#define RANGE_SEED_ADVANCE(name, stride) ((void)0)
#endif

// Exact score stream for a contiguous range. Each logical rank owns one output
// slot, so the host can read scores back in rank order without atomics or
// sorting. A literal cutoff of zero forces FILTER_USES_CUTOFF filters down their
// full-score path; no prefilter or printing is involved.
__kernel void search_scores(long start_rank, long num_seeds, __global long* out) {
    const long filter_cutoff = 0;
    long i = get_global_id(0);
    if (i >= num_seeds) return;
    long stride = get_global_size(0);
    RANGE_SEED_STATE(_seed, start_rank + i);
    for (; i < num_seeds; i += stride) {
        RANGE_SEED_LOAD(_seed, start_rank + i);
        instance inst;
        i_init(&inst, _seed);
        out[i] = RUN_FILTER(&inst);
        RANGE_SEED_ADVANCE(_seed, stride);
    }
}

// Single-pass search: every seed in [start_rank, start_rank + num_seeds) runs
// the filter and is printed if its score reaches the -c cutoff. Each iteration
// derives its seed directly from the logical rank already tracked by the loop.
__kernel void search(long start_rank, long num_seeds, long filter_cutoff) {
    long i = get_global_id(0);
    if (i >= num_seeds) return;
    long stride = get_global_size(0);
    RANGE_SEED_STATE(_seed, start_rank + i);
    for (; i < num_seeds; i += stride) {
        RANGE_SEED_LOAD(_seed, start_rank + i);
        instance inst;
        i_init(&inst, _seed);
        long score = RUN_FILTER(&inst);
        // The cutoff is the value given with -c and never changes during a run.
        if (score >= filter_cutoff) {
            s_print_score(&_seed, score);
        }
        RANGE_SEED_ADVANCE(_seed, stride);
    }
}

// Rank-list search with one work-GROUP per seed instead of one work-item.
//
// The default mapping gives each seed to a single work-item, so a filter whose
// own work is large is serial no matter how wide the device is, and the batch
// waits for the slowest seed on one thread. That is the binding constraint for
// tree-searching filters: a seed worth 59,049 leaf walks takes as long as one
// thread needs, and a consumer GPU thread running fp64 at 1/64 rate is slower
// at it than a CPU core.
//
// Here every lane of the group gets the same seed and the filter splits its own
// work across the group, reading get_local_id/get_local_size itself and
// returning that lane's best. The group maximum is reduced and printed once.
// Selected with --group_per_seed, which also defines GROUP_PER_SEED so the
// filter knows to split; a filter built without it would have every lane
// duplicate the whole search, which is correct but pointless.
//
// The reduction is a serial scan by lane 0 rather than a tree: it runs once per
// seed over at most a few hundred lanes, which is nothing beside the search,
// and it is correct for any work-group size rather than powers of two only.
__kernel void search_ranks_grouped(__global const long* ranks, long num_ranks,
                                   long filter_cutoff, __local long* scratch) {
    const uint lid = get_local_id(0);
    const uint lsz = get_local_size(0);
    // Every lane of a group shares group_id, so all of them make the same
    // number of trips and every barrier below is reached by the whole group.
    for (long g = (long)get_group_id(0); g < num_ranks; g += (long)get_num_groups(0)) {
        seed _seed = s_from_rank(ranks[g]);
        instance inst;
        i_init(&inst, _seed);
        scratch[lid] = RUN_FILTER(&inst);
        barrier(CLK_LOCAL_MEM_FENCE);
        if (lid == 0) {
            for (uint i = 1; i < lsz; i++) if (scratch[i] > scratch[0]) scratch[0] = scratch[i];
            if (scratch[0] >= filter_cutoff) s_print_score(&_seed, scratch[0]);
        }
        barrier(CLK_LOCAL_MEM_FENCE);
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
    RANGE_SEED_STATE(_seed, start_rank + (i < num_seeds ? i : 0));                      \
    long mine[COLLECT_CHUNK];                                                           \
    long rounds = (num_seeds + gsize * COLLECT_CHUNK - 1) / (gsize * COLLECT_CHUNK);    \
    for (long r = 0; r < rounds; r++) {                                                 \
        int n = 0;                                                                      \
        for (int k = 0; k < COLLECT_CHUNK; k++) {                                       \
            if (i < num_seeds) {                                                        \
                RANGE_SEED_LOAD(_seed, start_rank + i);                                 \
                instance inst;                                                          \
                i_init(&inst, _seed);                                                   \
                if (PRED) mine[n++] = start_rank + i;                                   \
                RANGE_SEED_ADVANCE(_seed, gsize);                                       \
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
