// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
// Removes: BUFFOON PACK CONTENTS (measured 170/seed, 0.32% of all draws) - the rarity, edition and
// identity draws (plus identity resamples) for each card of a Buffoon pack.
// Pack selection is untouched, and the temporary within-pack i_lock/i_unlock
// machinery is kept alive with a constant identity.
// Measures: what share of runtime the pack-contents path costs - it is the one
// stream that still goes through the un-staged, ordinal-major library helpers
// (next_joker_rarity / randchoice_common / next_joker_edition), so its
// cost-per-draw should be markedly worse than the staged shop path.
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_SUB_PACKCONTENTS 1
#include "filters/dns_sub_core.cl"
