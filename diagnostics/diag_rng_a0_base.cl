// diag_rng_a0_base
//
// Frozen reference copy of deep_negative_shops. Scores are CORRECT and are the
// baseline every other ratio in this pack is measured against.
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_BASE 1
#include "diagnostics/diag_rng_dns_body.cl"
