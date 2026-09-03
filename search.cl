// Single-pass search: every seed in [start_rank, start_rank + num_seeds) runs
// the filter and is printed if its score reaches the -c cutoff. Each lane
// derives its first seed from its rank once, then steps by the stride.
__kernel void search(long start_rank, long num_seeds, long filter_cutoff) {
    long i = get_global_id(0);
    if (i >= num_seeds) return;
    long stride = get_global_size(0);
    seed _seed = s_from_rank(start_rank + i);
    for (; i < num_seeds; i += stride) {
        instance inst = i_new(_seed);
        long score = filter(&inst);
        // The cutoff is the value given with -c and never changes during a run.
        if (score >= filter_cutoff) {
            text s_str = s_to_string(&_seed);
            printf("%s (%li)\n", s_str.str, score);
        }
        s_skip(&_seed, stride);
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
#ifndef PREFILTER_CHUNK
// Seeds per lane per aggregation round. Survivors are gathered per work-group
// through local memory and written with one global atomic per group per round,
// instead of one contended global atomic per surviving lane.
#define PREFILTER_CHUNK 8
#endif
__kernel void search_prefilter(long start_rank, long num_seeds, __global long* survivors, volatile __global uint* survivor_count) {
    __local uint group_base;
    __local uint group_count;
    long lid = get_local_id(0);
    long gsize = get_global_size(0);
    long i = get_global_id(0);
    seed _seed = s_from_rank(start_rank + (i < num_seeds ? i : 0));
    long mine[PREFILTER_CHUNK];
    // Every lane in the group must run the same number of rounds so the
    // barriers line up; lanes past the end just contribute nothing.
    long rounds = (num_seeds + gsize * PREFILTER_CHUNK - 1) / (gsize * PREFILTER_CHUNK);
    for (long r = 0; r < rounds; r++) {
        int n = 0;
        for (int k = 0; k < PREFILTER_CHUNK; k++) {
            if (i < num_seeds) {
                instance inst = i_new(_seed);
                if (prefilter(&inst)) mine[n++] = start_rank + i;
                s_skip(&_seed, gsize);
                i += gsize;
            }
        }
        if (lid == 0) group_count = 0;
        barrier(CLK_LOCAL_MEM_FENCE);
        uint my_off = n ? atomic_add(&group_count, (uint)n) : 0;
        barrier(CLK_LOCAL_MEM_FENCE);
        if (lid == 0) group_base = group_count ? atomic_add(survivor_count, group_count) : 0;
        barrier(CLK_LOCAL_MEM_FENCE);
        for (int k = 0; k < n; k++) survivors[group_base + my_off + k] = mine[k];
    }
}

__kernel void search_ranks(__global const long* ranks, long num_ranks, long filter_cutoff) {
    for (long i = get_global_id(0); i < num_ranks; i += get_global_size(0)) {
        seed _seed = s_from_rank(ranks[i]);
        instance inst = i_new(_seed);
        long score = filter(&inst);
        if (score >= filter_cutoff) {
            text s_str = s_to_string(&_seed);
            printf("%s (%li)\n", s_str.str, score);
        }
    }
}
#endif
