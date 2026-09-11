// diag_rng_a3_intstate
//
// ABLATION - PRODUCES DELIBERATELY WRONG SCORES.
// The whole fp64 node recurrence is replaced by an integer xorshift64,
// removing about 12 of the ~13 fp64 ops in the per-draw advance.
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_INTSTATE 1
#include "filters/diag_rng_dns_body.cl"
