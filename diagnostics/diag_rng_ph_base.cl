// diag_rng_ph_base -- DIAGNOSTIC MICROBENCHMARK, MEANINGLESS SCORES.
// Same loop shape with a cheap fp64 mul-add instead of ph_step.
// Never add to tests/golden/.
#define DIAG_PH_BASE 1
#include "diagnostics/diag_rng_ph_body.cl"
