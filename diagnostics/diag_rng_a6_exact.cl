// diag_rng_a6_exact
//
// BIT-EXACT CANDIDATE, not an ablation. Scores MUST match diag_rng_a0_base
// exactly; if they do not, the bundle is broken and the timing is void.
// Bundles four host-verified exact strength reductions (E1-E4 in the body).
//
// Diagnostic fixture for the fp64 RNG-core cost study. Never add this file to
// tests/golden/ or to any profile that compares against a golden.
// Run:  python3 tests/run.py --profile benchmark --scale rtx5080 \
//         --cases tests/diag_rng_benchmark.json
#define DIAG_VARIANT_EXACT 1
#include "diagnostics/diag_rng_dns_body.cl"
