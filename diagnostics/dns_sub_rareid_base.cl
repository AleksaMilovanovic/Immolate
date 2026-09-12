// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the RARE identity BASE draws only (measured 662/seed, 1.27% of all draws). The index
// becomes a deterministic sweep (o % itemCount) + 1, so the resample chain
// still fires at essentially the real locked fraction and the Blueprint /
// Brainstorm indices are still hit at the right rate. RESAMPLE chain intact.
// Measures: the cost of the base rare-identity draw alone, separated from its
// resample chain.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_RAREID_BASE 1
#include "diagnostics/dns_sub_core.cl"
