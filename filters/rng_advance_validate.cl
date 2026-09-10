#include "lib/immolate.cl"
#include "lib/rng_advance_int.cl"

// Differential prototype validator. Each seed rank selects one decimal-grid
// state, then native binary64 and guarded integer paths walk the same trajectory.
// Normal scores encode raw mismatches * 1000 + fallback count. A score at or
// above RNG13_MISMATCH_SENTINEL identifies a correctness failure; the low value
// is step * 16 + failure code.
#define RNG13_VALIDATE_STEPS 512

long filter(instance* inst) {
    ulong counter = (ulong)s_tell(&inst->seed);
    rng13_state state = rng13_validation_state(counter);
    int rawMismatches = 0;
    int fallbacks = 0;

    for (int stepIndex = 0; stepIndex < RNG13_VALIDATE_STEPS; stepIndex++) {
        rng13_candidate candidate = rng13_decimal_candidate(state);
        ulong candidateK = rng13_to_ulong(candidate.state);
        ulong nativeK = rng13_native_next_k(rng13_to_double(state));
        rng13_step guarded = rng13_guarded_next(state);
        ulong guardedK = rng13_to_ulong(guarded.state);

        if (candidateK > RNG13_SCALE) {
            return RNG13_MISMATCH_SENTINEL + (long)stepIndex * 16L + 4L;
        }
        if (guardedK > RNG13_SCALE) {
            return RNG13_MISMATCH_SENTINEL + (long)stepIndex * 16L + 5L;
        }
        if (candidate.safe && candidateK != nativeK) {
            return RNG13_MISMATCH_SENTINEL + (long)stepIndex * 16L + 1L;
        }
        if (guarded.usedFastPath != candidate.safe) {
            return RNG13_MISMATCH_SENTINEL + (long)stepIndex * 16L + 2L;
        }
        if (guardedK != nativeK) {
            return RNG13_MISMATCH_SENTINEL + (long)stepIndex * 16L + 3L;
        }

        rawMismatches += candidateK != nativeK;
        fallbacks += !candidate.safe;
        state = guarded.state;
    }

    return (long)rawMismatches * 1000L + (long)fallbacks;
}
