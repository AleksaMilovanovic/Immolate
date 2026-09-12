// DIAGNOSTIC FIXTURE - not a real filter, never wire into correctness goldens.
// All of the safe footprint reductions applied together:
//   CACHE_SIZE   256 -> 128   (-2048 B; P(per-ante peak > 128) ~ 2e-9, measured)
//   SEED_HASH_LENS 48 -> 24   (-192 B; DNS's longest node name is 22 chars, and
//                              an over-long name only recomputes, never differs)
//   INSTANCE_NO_DECK          (-208 B; DNS never touches params.deckCards, and
//                              a filter that did would fail to compile)
// params.vouchers[32] is NOT removed: activate_voucher / is_voucher_active read
// it on the DNS path. Scores must stay bit-identical to deep_negative_shops.
#define DNS_CACHE_SIZE_OVERRIDE 128
#define SEED_HASH_LENS 24
#define INSTANCE_NO_DECK
#include "filters/deep_negative_shops.cl"
