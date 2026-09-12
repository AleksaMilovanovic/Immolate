// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the TAG stream (exactly 72 draws/seed, 0.14% of all draws) - the two per-ante next_tag() calls
// for antes 3..38, replaced by a constant non-Negative tag. Side-effect free:
// tags gate no other work, so downstream volume is identical to baseline and
// only the two low score fields change (both go to zero).
// Measures: the tag stream's share of total runtime; also the family's
// negative control - if this one shows a large drop, the harness is measuring
// noise rather than stream cost.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_TAGS 1
#include "filters/dns_sub_core.cl"
