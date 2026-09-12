// diag_rng_a7_leanwarm
//
// BIT-EXACT CANDIDATE, not an ablation. Scores MUST match diag_rng_a0_base
// exactly; if they do not, the change is broken and the timing is void.
// Drops the dead XOR accumulator and dead out.ul store from randomseed's 10
// warmup rounds (see E5 in diag_rng_dns_body.cl). If the compiler already
// eliminated that work the ratio will be 1.00 and the idea is dead.
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
#define DIAG_VARIANT_LEANWARM 1
#include "diagnostics/diag_rng_dns_body.cl"
