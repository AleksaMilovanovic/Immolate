// diag_rng_a5_norngcore
//
// ABLATION - PRODUCES DELIBERATELY WRONG SCORES.
// randomseed() and l_random() are both replaced by a single xorshift64.
// Bounds the entire LuaJIT RNG core (seeding + warmup + output draw).
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_NORNGCORE 1
#include "filters/diag_rng_dns_body.cl"
