// DIAGNOSTIC FIXTURE - not a real filter, never wire into correctness goldens.
// deep_negative_shops with CACHE_SIZE forced to 64.
//
// *** THIS BUILD PRODUCES WRONG SCORES. *** The measured per-ante peak live
// node count for DNS is p50 34 / p99 52 / max 83 over 20,480 stratified seeds,
// so 64 slots overflow on a fraction of seeds and init_node then silently
// reuses the last slot. The overflow warning is suppressed so the harness can
// still record a timing; the timing is the only output worth reading here.
#define DNS_CACHE_SIZE_OVERRIDE 64
#define DIAG_SILENCE_CACHE_OVERFLOW
#include "filters/deep_negative_shops.cl"
