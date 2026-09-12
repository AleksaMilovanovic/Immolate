// diag_rng_a2_noround
//
// ABLATION - PRODUCES DELIBERATELY WRONG SCORES.
// The node recurrence keeps fract() but drops roundDigits/round/div_1e13,
// removing about 5 of the ~13 fp64 ops in the per-draw advance.
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_NOROUND 1
#include "diagnostics/diag_rng_dns_body.cl"
