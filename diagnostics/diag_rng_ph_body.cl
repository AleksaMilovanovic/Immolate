// ===========================================================================
// DIAGNOSTIC MICROBENCHMARK -- PRODUCES DELIBERATELY MEANINGLESS SCORES.
// Never add to tests/golden/ or to any golden-comparing profile.
//
// Isolates the cost of one ph_step() (the per-character pseudohash step:
// div_pos + 3 fp64 multiplies + 4 fract + a double<->long round trip).
//
// diag_rng_ph_micro   runs DIAG_PH_STEPS real ph_step calls per work-item.
// diag_rng_ph_base    runs the same loop with a cheap fp64 mul-add instead.
//
// The measured difference divided by DIAG_PH_STEPS is the per-ph_step cost on
// the target device. Instrumented DNS counts give 11,334 ph_step calls and
// 50,202 RNG draws per seed (seed 11111111), so
//     hash share of DNS = 11,334 * cost(ph_step) / total DNS time per seed.
//
// PREDICTION: under the fp64-throughput model ph_step costs about 23 fp64 ops
// versus about 27 for a whole draw, so ph_step is ~0.85 draws. With 11,334
// calls against 50,202 draws the hash should be ~16% of the fp64 work and
// ~13% of modelled DNS time. If the measured hash share comes out below ~5%,
// the pseudohash is finished as an optimisation target and every remaining
// hash idea can be dropped.
// ===========================================================================
#define CACHE_SIZE 1
#include "lib/immolate.cl"

#ifndef DIAG_PH_STEPS
#define DIAG_PH_STEPS 8192
#endif

long filter(instance* inst) {
    double h = inst->hashedSeed;
    int pos = 8;
    for (int i = 0; i < DIAG_PH_STEPS; i++) {
#ifdef DIAG_PH_BASE
        h = fract(h * 1.72431234 + 2.134453429141);   // cheap stand-in
#else
        h = ph_step(h, 49 + (i & 7), pos);
#endif
        pos = 4 + ((pos + 1) & 15);
    }
    return (long)(h * 4503599627370496.0) & 0x0FFFFFFFFFFFFFFFL;
}
