// DIAGNOSTIC FIXTURE - RETURNS THE NORMAL SCORE, ON PURPOSE.
// Not a measurement fixture and not a golden: it is the guard for the
// dns_cnt_* family.
//
// Turns the draw counters on but leaves the packing off, so the filter returns
// its ordinary score. The counting build swaps lib's randchoice_common,
// next_voucher and the filter's dns_joker for hand-written replicas (the only
// way to observe lib-internal resample draws without editing lib/). If those
// replicas have drifted from lib, the RNG stream shifts and the score changes.
//
// PASS CONDITION: this fixture's scores are bit-identical to
// filters/deep_negative_shops.cl on the same seeds. If they are not, every
// dns_cnt_draws / dns_cnt_draws2 number is void.
//
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_CNT 1
#include "filters/dns_sub_core.cl"
