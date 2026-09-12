// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: the UNCOMMON identity BASE draws only (measured 3,333/seed, 6.4% of all draws) - the one
// draw per uncommon ordinal in dns_flush_identities. The index becomes a
// deterministic sweep (o % itemCount) + 1, so the resample chain that follows
// still fires at essentially the real locked fraction and the Diet Cola index
// is still hit at 1/itemCount. The RESAMPLE chain is left fully intact.
// Measures: the cost of the base uncommon-identity draw alone, separated from
// its resample chain - lumping the two is what hid the effect last round.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_UNCID_BASE 1
#include "filters/dns_sub_core.cl"
