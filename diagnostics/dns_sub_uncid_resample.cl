// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the UNCOMMON identity RESAMPLE chain only (measured 1,739/seed, 3.3% of all draws) - the
// depth-major while-loop over locked ordinals and its resample_<d> nodes. Every
// index is treated as unlocked. The BASE draw is kept exactly as shipped.
// Measures: the cost of the divergent, data-dependent resample chain alone -
// the part that is expected to dominate on a warp because its depth is the max
// over 32 lanes of a geometric variable.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_UNCID_RESAMPLE 1
#include "diagnostics/dns_sub_core.cl"
