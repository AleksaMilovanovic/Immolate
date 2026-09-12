// DIAGNOSTIC FIXTURE - not a real filter, never wire into correctness goldens.
// The zero-risk subset of diag_mem_composite: CACHE_SIZE stays at the measured
// safe 256, only the two reductions with no correctness tail are applied.
//   SEED_HASH_LENS 48 -> 24   (-192 B)
//   INSTANCE_NO_DECK          (-208 B)
#define SEED_HASH_LENS 24
#define INSTANCE_NO_DECK
#include "filters/deep_negative_shops.cl"
