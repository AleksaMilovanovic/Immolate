// Single-pass search: every seed in [start_rank, start_rank + num_seeds) runs
// the filter and is printed if its score reaches the -c cutoff.
__kernel void search(long start_rank, long num_seeds, long filter_cutoff) {
    for (long i = get_global_id(0); i < num_seeds; i += get_global_size(0)) {
        seed _seed = s_from_rank(start_rank + i);
        instance inst = i_new(_seed);
        long score = filter(&inst);
        // The cutoff is the value given with -c and never changes during a run.
        if (score >= filter_cutoff) {
            text s_str = s_to_string(&_seed);
            printf("%s (%li)\n", s_str.str, score);
        }
    }
}

// Two-pass search, used when the filter defines HAS_PREFILTER and
//     bool prefilter(instance* inst)
// which must return true for every seed whose filter() score could reach the
// cutoff (false positives are fine, false negatives lose seeds). Pass 1 runs
// only the cheap prefilter on every seed and records survivors' ranks. Pass 2
// runs the full filter on the survivors, packed contiguously, so every lane in
// a warp is doing the same expensive work instead of idling behind one deep
// seed. This matters for filters whose per-seed cost varies by orders of
// magnitude between early rejects and full evaluations.
#ifdef HAS_PREFILTER
__kernel void search_prefilter(long start_rank, long num_seeds, __global long* survivors, volatile __global uint* survivor_count) {
    for (long i = get_global_id(0); i < num_seeds; i += get_global_size(0)) {
        long rank = start_rank + i;
        seed _seed = s_from_rank(rank);
        instance inst = i_new(_seed);
        if (prefilter(&inst)) {
            // The host never launches more seeds than the buffer holds, so
            // this index cannot run off the end.
            uint idx = atomic_inc(survivor_count);
            survivors[idx] = rank;
        }
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
