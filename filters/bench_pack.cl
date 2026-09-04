#include "lib/immolate.cl"
// Microbenchmark: the cost of learning the first shop pack's type, which is
// wr_filter's gate 1 before the soul and Perkeo checks. Two node creations,
// two draws. Run with -c 11 so nothing prints.
long filter(instance* inst) {
    next_pack(inst, 1);
    return (long)pack_info(next_pack(inst, 1)).type % 5;
}
