// diag_rng_a4_noseedfp
//
// ABLATION - PRODUCES DELIBERATELY WRONG SCORES.
// randomseed()'s four serial (d*pi; d+e) fp64 rounds are replaced by an
// integer mix; the 10-round warmup is kept. Removes 8 fp64 ops per draw.
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_NOSEEDFP 1
#include "filters/diag_rng_dns_body.cl"
