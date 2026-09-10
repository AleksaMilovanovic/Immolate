#include "lib/immolate.cl"
#include "lib/rng_advance_int.cl"

// Paired recurrence microbenchmark. Includes the guarded limb transition, real
// native fallback path, and conversion of every next state back to binary64.
// Run with -c 11 so no records print.
#define RNG13_BENCH_STEPS 512

long filter(instance* inst) {
    ulong counter = (ulong)s_tell(&inst->seed);
    rng13_state state = rng13_validation_state(counter);
    uint acc = (uint)counter ^ (uint)(counter >> 32);

    for (int i = 0; i < RNG13_BENCH_STEPS; i++) {
        state = rng13_guarded_next(state).state;
        dbllong bits;
        bits.d = rng13_to_double(state);
        acc = (acc << 5) | (acc >> 27);
        acc ^= (uint)bits.ul ^ (uint)(bits.ul >> 32);
    }

    return (long)(acc % 5U);
}
