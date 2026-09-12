// DIAGNOSTIC FIXTURE - RETURNS PACKED DRAW COUNTERS, NOT SCORES.
// Never wire this into correctness goldens; the "score" column is a bit field.
//
// Second half of the per-stream RNG draw census; see filters/dns_cnt_draws.cl
// for the first half and the rationale. Counting only - do NOT time this.
//
// PACKING - one unsigned field per stream, low bit first, 63 bits total:
//   bits [ 0..10] 11b  rare identity BASE draws
//   bits [11..22] 12b  rare identity RESAMPLE draws
//   bits [23..35] 13b  buffoon pack CONTENTS draws
//                      (per pack card: 1 rarity + 1 identity + identity
//                       resamples + 1 edition)
//   bits [36..44]  9b  pack SELECTION draws (next_pack; exactly 216 at the
//                      default DNS_PACKS=6 over antes 3..38 - a fixed value,
//                      so it doubles as a counter sanity check)
//   bits [45..53]  9b  VOUCHER draws including resamples (one next_voucher per
//                      ante 1..38; ~half the 32-voucher pool starts locked, so
//                      expect ~76)
//   bits [54..62]  9b  TAG draws including resamples (two next_tag per ante
//                      3..38, so >= 72)
// A counter that does not fit its field poisons the seed with -1 rather than
// truncating silently, so any -1 in the output invalidates that seed.
//
// Decode (python):  x=int(score); [ (x>>s)&((1<<w)-1) for s,w in
//   ((0,11),(11,12),(23,13),(36,9),(45,9),(54,9)) ]
//
// Implementation: COPY, not a #define hook on the shipped filter - it goes
// through filters/dns_sub_core.cl, an instrumented copy of
// deep_negative_shops.cl that must be re-synced BY HAND when that file changes.
#define DNS_CNT 1
#define DNS_CNT_DRAWS2 1
#include "diagnostics/dns_sub_core.cl"
