// ===========================================================================
// DIAGNOSTIC FIXTURE BODY -- NOT A CORRECTNESS ARTEFACT.
// PRODUCES DELIBERATELY MEANINGLESS SCORES (it is a microbenchmark, not a
// filter). Never add any diag_rng_chain_* fixture to tests/golden/ or to any
// profile that compares against a golden.
//
// Latency-vs-throughput probe for the per-draw RNG chain.
//
// Each work-item runs DIAG_CHAIN_TOTAL complete
//     advance -> randomseed -> l_random
// chains. The only thing that changes between the K variants is how many of
// those chains are in flight at once: DIAG_K independent stream states are
// advanced inside one unrolled inner step, so the total arithmetic is
// identical for every K and only the available instruction-level parallelism
// changes.
//
// CACHE_SIZE is pinned to 256, the value deep_negative_shops uses, so the
// `instance` footprint (and therefore the occupancy the kernel achieves) is
// the same as the real filter's. The instance is otherwise unused except as a
// source of DIAG_K independent starting states.
//
// PREDICTIONS (state before running):
//   H_throughput -- the kernel is bound by fp64 issue throughput.
//       t(K)/t(1) ~ 1.00 for K = 2 and 4, and 1.00-1.20 at K = 8 as register
//       pressure starts to spill. No downward trend at all.
//   H_latency -- the kernel is bound by the serial dependent chain.
//       t(K)/t(1) ~ 0.50 at K = 2, ~0.30 at K = 4, flat or worse at K = 8.
//       (The analytic chain/throughput ratio is ~3, so the curve should
//       flatten around K = 3-4.)
// Any result between those two shapes is partial latency exposure; read the
// K at which the curve flattens as the effective ILP deficit.
//
// K = 8 keeps ~8 x (1 double state + 1 lrandom = 5 x 64-bit) live, i.e. about
// 176 32-bit registers before temporaries. Expect spills at K = 8 on a 255-
// register budget; treat K = 8 as contaminated unless K = 4 already answers it.
// ===========================================================================
#define CACHE_SIZE 256
#include "lib/immolate.cl"

#ifndef DIAG_K
#define DIAG_K 1
#endif
// Total chains per work-item. Must be a multiple of 8 so every K variant does
// exactly the same number of chains.
#ifndef DIAG_CHAIN_TOTAL
#define DIAG_CHAIN_TOTAL 4096
#endif

long filter(instance* inst) {
    double s[DIAG_K];
    // DIAG_K independent starting states in [0, 1), derived from the seed hash
    // so nothing is compile-time constant and nothing can be hoisted.
    for (int k = 0; k < DIAG_K; k++) {
        s[k] = fract(inst->hashedSeed * (double)(k + 1) * 1.234567 + 0.31831);
    }
    ulong acc = 0;
    const int steps = DIAG_CHAIN_TOTAL / DIAG_K;
    for (int i = 0; i < steps; i++) {
        #pragma unroll
        for (int k = 0; k < DIAG_K; k++) {
            s[k] = roundDigits(fract(s[k] * 1.72431234 + 2.134453429141), 13);
            lrandom lr = randomseed((s[k] + inst->hashedSeed) / 2);
            // Consume the draw into an integer accumulator so nothing is dead.
            acc += (ulong)(l_random(&lr) * 4503599627370496.0);
        }
    }
    return (long)(acc & 0x0FFFFFFFFFFFFFFFL);
}
