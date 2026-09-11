// diag_rng_a1_nowarmup
//
// ABLATION - PRODUCES DELIBERATELY WRONG SCORES.
// randomseed()'s 10-round Tausworthe warmup is deleted (10 -> 0 rounds),
// removing 40 of the 44 shift/xor word-updates per draw.
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_NOWARMUP 1
#include "filters/diag_rng_dns_body.cl"
