// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: PACK SELECTION, i.e. next_pack() (exactly 216 draws/seed, 0.41% of all draws, one
// weighted draw per pack). Replaced by a deterministic cycle that reproduces the real Buffoon
// share (PACKS gives 1.95/22.42 = 8.7%, the cycle gives 1/12 = 8.3%) and the
// 8:4:1 plain/Jumbo/Mega split (mean size 2.77, same as PACKS), so
// pack-contents work volume is preserved.
// Measures: the cost of the weighted pack draw, separated from pack contents.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_PACKSEL 1
#include "filters/dns_sub_core.cl"
