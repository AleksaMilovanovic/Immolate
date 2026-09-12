// diag_rng_chain_k2
//
// DIAGNOSTIC MICROBENCHMARK - PRODUCES DELIBERATELY MEANINGLESS SCORES.
// 2 independent RNG chains in flight per inner step; identical total work
// to every other diag_rng_chain_k* fixture. See diag_rng_chain_body.cl for
// the two predicted curve shapes.
// Never add to tests/golden/ or to any golden-comparing profile.
#define DIAG_K 2
#include "diagnostics/diag_rng_chain_body.cl"
