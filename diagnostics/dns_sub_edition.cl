// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the shop joker EDITION / negative poll (measured 13,293/seed, 25.4% of all draws; exactly one per rarity poll). Every
// shop joker is treated as non-Negative. Negative is ~0.3% and gates no further
// draws, so downstream work volume is identical to baseline; only the score
// changes (shop copy/uncommon/other negatives all drop to zero).
// Measures: the edition stream's share of total runtime, with the cleanest
// work-volume invariance of the whole family.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_EDITION 1
#include "diagnostics/dns_sub_core.cl"
