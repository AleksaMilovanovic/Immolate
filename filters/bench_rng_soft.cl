#include "lib/immolate.cl"
#include "lib/rng_seed_soft.cl"
// Microbenchmark matching bench_rng_int, but randomseed's four multiply/add
// rounds use exact uint-limb binary64 operations instead of native fp64.
long filter(instance* inst) {
    double acc = 0;
    for (int i = 0; i < 52; i++) {
        lrandom rng = soft_randomseed(inst->hashedSeed + i * 0.001);
        acc += l_random(&rng);
    }
    return (long)(acc * 1000) % 5;
}
