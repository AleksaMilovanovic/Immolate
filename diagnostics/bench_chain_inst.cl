// Microbenchmark, not a filter. One half of a pair with bench_chain_regs.
//
// This half is the production RNG path: 38 antes, two tag draws per ante with
// Foil/Holographic/Polychrome rerolled, every node created, looked up and
// advanced through the `instance` node cache exactly as negative_tags does
// (it is negative_tags -c 0 without init_locks/init_unlocks). The other half
// runs the identical schedule and arithmetic with all RNG state in registers.
// Both return first-slot*100 + second-slot Negative Tag counts, so their
// score streams must be identical; run both with -c 9999 so nothing prints.
#define CACHE_SIZE 32
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef BC_MAX_ANTE
#define BC_MAX_ANTE 38
#endif

long filter(instance* inst) {
    i_lock(inst, Foil_Tag);
    i_lock(inst, Holographic_Tag);
    i_lock(inst, Polychrome_Tag);
    long n1 = 0, n2 = 0;
    for (int ante = 1; ante <= BC_MAX_ANTE; ante++) {
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        if (next_tag(inst, ante) == Negative_Tag) n1++;
        if (next_tag(inst, ante) == Negative_Tag) n2++;
    }
    return n1 * 100 + n2;
}
