// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the shop joker RARITY poll (measured 13,293/seed, 25.4% of all draws). Rarity comes from a
// deterministic 20-slot cycle that reproduces the real 5% rare / 25% uncommon /
// 70% common split, so the uncommon and rare identity streams below still
// receive the same number of ordinals.
// Measures: the rarity stream's share of total runtime.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_RARITY 1
#include "filters/dns_sub_core.cl"
