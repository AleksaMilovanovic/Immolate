#include "lib/immolate.cl"
#include "lib/rng_advance_int.cl"

// Paired recurrence microbenchmark. This side keeps the production binary64
// transition; bench_rng_advance_hybrid uses the same starts, steps, and visible
// bit accumulation. Run with -c 11 so no records print.
#define RNG13_BENCH_STEPS 512

long filter(instance* inst) {
    ulong counter = (ulong)s_tell(&inst->seed);
    double state = rng13_to_double(rng13_validation_state(counter));
    uint acc = (uint)counter ^ (uint)(counter >> 32);

    for (int i = 0; i < RNG13_BENCH_STEPS; i++) {
        state = rng13_native_next(state);
        dbllong bits;
        bits.d = state;
        acc = (acc << 5) | (acc >> 27);
        acc ^= (uint)bits.ul ^ (uint)(bits.ul >> 32);
    }

    return (long)(acc % 5U);
}
