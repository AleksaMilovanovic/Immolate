__kernel void search(char8 starting_seed, long num_seeds, long filter_cutoff) {
    seed _seed = s_new_c8(starting_seed);
    s_skip(&_seed, get_global_id(0));
    for (long i = get_global_id(0); i < num_seeds; i+=get_global_size(0)) {
        instance inst = i_new(_seed);
        long score = filter(&inst);
        // The cutoff is the value given with -c and never changes during a run.
        // Every seed scoring at or above it is printed. (Earlier versions raised
        // the cutoff to the best score seen so far through a racy global write
        // and a barrier inside this branch; that was undefined behaviour and
        // would deadlock at work-group sizes of a warp or more.)
        if (score >= filter_cutoff) {
            text s_str = s_to_string(&_seed);
            printf("%s (%li)\n", s_str.str, score);
        }
        s_skip(&_seed,get_global_size(0));
    }
}
