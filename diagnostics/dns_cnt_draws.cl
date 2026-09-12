// DIAGNOSTIC FIXTURE - RETURNS PACKED DRAW COUNTERS, NOT SCORES.
// Never wire this into correctness goldens; the "score" column is a bit field.
//
// Counts the ACTUAL RNG draws each work-generating stream performs per seed, so
// cost-per-draw can be computed from the Family B ablation timings rather than
// assumed from the old estimates. Counting only - do NOT time this fixture; the
// counters themselves cost work.
//
// The RNG stream is untouched: counters are pure increments, and the lib calls
// that hide their resamples (randchoice_common, next_voucher) are replaced by
// exact replicas that make the same calls in the same order.
// filters/dns_cnt_selfcheck.cl proves that by returning the normal score.
//
// PACKING - one unsigned field per stream, low bit first, 63 bits total:
//   bits [ 0..14] 15b  shop card-type draws          (hard max 20964)
//   bits [15..29] 15b  shop joker rarity draws       (hard max = card-type)
//   bits [30..42] 13b  uncommon identity BASE draws
//   bits [43..55] 13b  uncommon identity RESAMPLE draws
//   bit  [56]      1b  edition draws == rarity draws; MUST read 1
//                      (the two are equal by construction - one edition poll
//                      per rarity poll - so edition is stored as a check bit
//                      and the 15 bits it would cost are spent elsewhere)
//   bits [57..62]  6b  reserved, always 0
// A counter that does not fit its field poisons the seed with -1 rather than
// truncating silently, so any -1 in the output invalidates that seed.
//
// Decode (python):  x=int(score); [ (x>>s)&((1<<w)-1) for s,w in
//   ((0,15),(15,15),(30,13),(43,13),(56,1)) ]
//
// Remaining streams are in filters/dns_cnt_draws2.cl.
//
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_CNT 1
#define DNS_CNT_DRAWS 1
#include "diagnostics/dns_sub_core.cl"
