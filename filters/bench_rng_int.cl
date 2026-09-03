#include "lib/immolate.cl"
// Microbenchmark, not a real filter. Isolates the LuaJIT RNG cost (randomseed's
// 4-word setup, 10 Tausworthe warmup steps, one draw) from the fp64 hashing
// path. 52 seeded draws per seed like erratic_flush_five, but the seed value is
// derived arithmetically instead of through pseudohash/roundDigits.
// Run with -c 11 so nothing prints; compare "Done in" against
// erratic_flush_five and bench_hash_fp64 over the same -s/-n.
long filter(instance* inst) {
    double acc = 0;
    for (int i = 0; i < 52; i++) {
        inst->rng = randomseed(inst->hashedSeed + i * 0.001);
        acc += l_random(&(inst->rng));
    }
    return (long)(acc * 1000) % 5;
}
