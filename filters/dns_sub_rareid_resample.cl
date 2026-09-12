// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the RARE identity RESAMPLE chain only (measured 807/seed, 1.54% of all draws) - the
// depth-major while-loop and its resample_<d> nodes; every index is treated as
// unlocked. The BASE draw is kept exactly as shipped. The rare pool is
// p_locked = 11/20, so this chain is longer per ordinal than the uncommon one
// despite there being far fewer rare ordinals.
// Measures: the cost of the rare resample chain alone, i.e. how much of the
// rare pool's cost is the lock-reroll rather than the draw.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_RAREID_RESAMPLE 1
#include "filters/dns_sub_core.cl"
