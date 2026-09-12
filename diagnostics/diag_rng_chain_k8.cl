// diag_rng_chain_k8
//
// DIAGNOSTIC MICROBENCHMARK - PRODUCES DELIBERATELY MEANINGLESS SCORES.
// 8 independent RNG chains in flight per inner step; identical total work
// to every other diag_rng_chain_k* fixture. See diag_rng_chain_body.cl for
// the two predicted curve shapes.
// Never add to tests/golden/ or to any golden-comparing profile.
#define DIAG_K 8
#include "diagnostics/diag_rng_chain_body.cl"
