#include "lib/immolate.cl"
// Microbenchmark, not a real filter. Isolates the fp64 path of get_node_child
// (node string pseudohash once, then 51 cached advances through fract and the
// roundDigits divide) from the RNG. Same node-state work per seed as
// erratic_flush_five, with no randomseed calls.
// Run with -c 11 so nothing prints; compare "Done in" against
// erratic_flush_five and bench_rng_int over the same -s/-n.
long filter(instance* inst) {
    double acc = 0;
    for (int i = 0; i < 52; i++) {
        acc += get_node_child(inst, (__private ntype[]){N_Type}, (__private int[]){R_Erratic}, 1);
    }
    return (long)(acc * 1000) % 5;
}
