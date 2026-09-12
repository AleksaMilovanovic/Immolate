// ===========================================================================
// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES
//
// dns_sub_core.cl is NOT a fixture to wire up on its own. It is the single
// shared, instrumented COPY of filters/deep_negative_shops.cl used by BOTH
// diagnostic families:
//   Family B  filters/dns_sub_<factor>.cl - subtractive ablations; each is a
//             two-line file that #defines one DNS_SUB_<FACTOR> and includes
//             this file. WRONG SCORES by design.
//   Family C  filters/dns_cnt_*.cl - draw counters; they #define DNS_CNT (plus
//             a packing switch) and include this file. They return COUNTERS,
//             not scores.
// One copy is kept rather than one per fixture precisely to halve the
// hand-sync surface. Regenerating it is a mechanical re-apply of 26 anchored
// hunks onto the shipped filter; if an anchor stops matching, the shipped
// filter has moved under a hook and this file must be re-derived by hand.
//
// WHY A COPY: the shipped filter exposes no hook for any of these streams
// (only DNS_CHUNK / DNS_PACKS / DNS_FIRST_ANTE / DNS_LAST_ANTE /
// DNS_CACHE_SIZE_OVERRIDE / DIAG_BALLAST_KB), so the ablations have to be
// edited in. KNOWN HAZARD: this copy must be re-synced BY HAND whenever
// filters/deep_negative_shops.cl changes. Copied from the `optimizations`
// working tree (DNS_CHUNK / DNS_MASK_WORDS / dns_flush_identities revision).
//
// SELF-CHECK: with no DNS_SUB_* switch defined, this file is byte-equivalent
// in behaviour to the shipped filter and MUST reproduce its exact scores. If
// it does not, the copy has drifted and every dns_sub_* result is void.
//
// Switches (exactly one per fixture):
//   DNS_SUB_CARDTYPE        shop card-type poll -> constant joker count
//   DNS_SUB_RARITY          shop joker rarity poll -> deterministic 70/25/5 cycle
//   DNS_SUB_EDITION         shop joker edition poll -> constant "not Negative"
//   DNS_SUB_UNCID_BASE      uncommon identity BASE draw -> deterministic sweep
//   DNS_SUB_UNCID_RESAMPLE  uncommon identity RESAMPLE chain -> all unlocked
//   DNS_SUB_RAREID_BASE     rare identity BASE draw -> deterministic sweep
//   DNS_SUB_RAREID_RESAMPLE rare identity RESAMPLE chain -> all unlocked
//   DNS_SUB_PACKSEL         next_pack() -> deterministic pack cycle
//   DNS_SUB_PACKCONTENTS    buffoon pack joker draws -> constant identities
//   DNS_SUB_VOUCHERS        next_voucher() -> constant (no Overstock growth)
//   DNS_SUB_TAGS            next_tag() -> constant non-Negative tag
//
// Counting switches (see the dns_cnt_* headers for the bit layouts):
//   DNS_CNT                 enable per-stream draw counters (no score change)
//   DNS_CNT_DRAWS           return counter pack 1 instead of the score
//   DNS_CNT_DRAWS2          return counter pack 2 instead of the score
// ===========================================================================
// Deep shop scan, antes 3-38: negative jokers, Diet Colas and Negative Tags.
// Meant to run over a seed-supplier pool (--from); at ~11,000 shop cards per
// seed it is far too slow for a raw walk.
//
// Shops. Each ante has a number of shop "frames" (reroll windows):
//   ante 3: 30;  antes 4-10: 80 + 3 per ante;  antes 11-15: 100 + 4 per ante;
//   ante 16 on: +5 per ante (121 at ante 16, 231 at ante 38).
// A frame is 2 cards, 3 from the ante Overstock is first seen or from ante 12,
// and 4 from the ante Overstock Plus is first seen or from ante 24. Cards per
// ante is frames * frame size. Also the ante's DNS_PACKS packs, Buffoon only.
//
// Vouchers. The ante voucher is generated for every ante from 1 (an early
// Overstock enlarges the ante-3 shop). The first sighting of Overstock,
// Clearance Sale, Reroll Surplus, Telescope, Grabber, Wasteful, Seed Money,
// Blank, Director's Cut, Paint Brush or Hieroglyph, or of any of their
// upgrades, counts as bought: it leaves the pool and unlocks its upgrade, as in
// the game. Upgrades start locked. None of these change shop card-type rates.
//
// Per joker (shop slot or pack card):
//   Diet Cola                      -> other
//   else if Negative edition:
//     Brainstorm / Blueprint       -> copy
//     Uncommon rarity              -> uncommon
//     anything else                -> other
// Tags: for antes 3-38, first-slot and second-slot Negative Tags counted apart.
// Joker locks: see the LOCKED / UNLOCKED lists below the include.
//
// Score, five 3-digit fields high to low:
//   copy | uncommon | other | first-tag negatives | second-tag negatives
// e.g. 1 negative copy joker, 3 negative uncommons, 7 other, 2 first tags and
// 1 second tag prints as 1003007002001.
//
// Draws skipped, all exact (same reasoning as wr_filter): consumable identities
// for non-joker slots, and the sticker and rental polls, which live on their
// own nodes and cannot fire at White Stake. Common shop identities are also
// skipped: Diet Cola is Uncommon, copy jokers are Rare, so every Negative Common
// scores as other regardless of identity. Uncommon/Rare shop identities and all
// Buffoon identities are still drawn because their values affect the score or
// temporary within-pack locks.
// Older versions used one global shop-pack RNG stream, so only versions whose
// pack node includes the ante may discard completed-ante nodes.
#define DNS_VERSION_AT_MOST(v1,v2,v3,v4) \
    ((VER1 < v1) || (VER1 == v1 && ((VER2 < v2) || \
    (VER2 == v2 && ((VER3 < v3) || (VER3 == v3 && VER4 <= v4))))))
#ifndef GAME_VERSION
    #define DNS_ANTE_LOCAL_CACHE 1
#elif VER1 == 0 || defined(DEMO)
    #if DNS_VERSION_AT_MOST(0,9,3,12)
        #define DNS_ANTE_LOCAL_CACHE 0
    #else
        #define DNS_ANTE_LOCAL_CACHE 1
    #endif
#else
    #if DNS_VERSION_AT_MOST(1,0,0,2)
        #define DNS_ANTE_LOCAL_CACHE 0
    #else
        #define DNS_ANTE_LOCAL_CACHE 1
    #endif
#endif

// Across 20,480 stratified seeds the per-ante peak was 80 nodes (p99 51).
// Keep legacy global-pack versions at the original cumulative capacity.
// Measured over 20,480 stratified seeds: per-ante peak p50 34, p90 41, p99 52,
// p99.9 62, max 83. The upper tail is exponential (ratio 0.818/node), so
// P(peak > 256) ~ 1e-20 and P(peak > 128) ~ 2e-9. 256 keeps overflow -- which
// silently corrupts that seed's score -- unreachable.
// DNS_CACHE_SIZE_OVERRIDE exists only for the footprint diagnostics in
// tests/diagnostics.json; leave it undefined for real runs.
#if DNS_ANTE_LOCAL_CACHE
    #ifdef DNS_CACHE_SIZE_OVERRIDE
        #define CACHE_SIZE DNS_CACHE_SIZE_OVERRIDE
    #else
        #define CACHE_SIZE 256
    #endif
#else
    #define CACHE_SIZE 2048
#endif
#include "lib/immolate.cl"
#undef DNS_VERSION_AT_MOST

// ---------------------------------------------------------------------------
// Joker locks. A locked joker cannot appear: when the game rolls one it
// rerolls within the same rarity, which shifts every later draw from that
// rarity pool. The LOCKED lists below are the jokers a fresh Balatro profile
// has not yet unlocked (taken from init_locks in lib/instance.cl, split by
// rarity). Anything in an UNLOCKED list is removed from the locks again, so to
// search as a profile that has earned Blueprint, add Blueprint to
// DNS_UNLOCKED_RARES and leave the LOCKED lists alone. An empty list is {}.
// Rerolls are exact: randchoice_common resamples on its own node sequence,
// the same way the game does.
// ---------------------------------------------------------------------------
__constant item DNS_LOCKED_COMMONS[] = {
    Golden_Ticket, Swashbuckler, Hanging_Chad, Shoot_the_Moon
};
__constant item DNS_LOCKED_UNCOMMONS[] = {
    Mr_Bones, Acrobat, Sock_and_Buskin, Troubadour, Certificate, Smeared_Joker, Throwback,
    Rough_Gem, Bloodstone, Arrowhead, Onyx_Agate, Glass_Joker, Showman, Flower_Pot, Merry_Andy,
    Oops_All_6s, The_Idol, Seeing_Double, Matador, Satellite, Cartomancer, Astronomer, Bootstraps
};
__constant item DNS_LOCKED_RARES[] = {
    Blueprint, Wee_Joker, Hit_the_Road, The_Duo, The_Trio, The_Family, The_Order, The_Tribe,
    Stuntman, Invisible_Joker, Brainstorm, Drivers_License, Burnt_Joker
};
__constant item DNS_UNLOCKED_COMMONS[] = {};
__constant item DNS_UNLOCKED_UNCOMMONS[] = {Showman};
__constant item DNS_UNLOCKED_RARES[] = {Blueprint, Brainstorm};

#define DNS_APPLY_LOCKS(list, fn) for (int _i = 0; _i < (int)(sizeof(list) / sizeof(item)); _i++) fn(inst, list[_i]);

#ifndef DNS_FIRST_ANTE
#define DNS_FIRST_ANTE 3
#endif
#ifndef DNS_LAST_ANTE
#define DNS_LAST_ANTE 38
#endif
#ifndef DNS_PACKS
#define DNS_PACKS 6
#endif

__constant item DNS_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item DNS_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

int dns_frames(int ante) {
    if (ante <= 3) return 30;
    if (ante <= 10) return 80 + 3 * (ante - 4);
    if (ante <= 15) return 100 + 4 * (ante - 11);
    return 116 + 5 * (ante - 15);
}

typedef struct DnsCounts {
    int copy, uncommon, other;
} dns_counts;

inline double dns_rng_node_advance_scalar(instance* inst, double* state) {
    *state = roundDigits(fract(*state * 1.72431234 + 2.134453429141), 13);
    return (*state + inst->hashedSeed) / 2;
}

inline double dns_random_scalar(
    instance* inst,
    double* state,
    lrandom* scratch
) {
    *scratch = randomseed(dns_rng_node_advance_scalar(inst, state));
    return l_random(scratch);
}

inline rarity dns_joker_rarity_scalar(
    instance* inst,
    double* state,
    lrandom* scratch
) {
    double poll = dns_random_scalar(inst, state, scratch);
    if (poll > 0.95) return Rarity_Rare;
    if (poll > 0.7) return Rarity_Uncommon;
    return Rarity_Common;
}

inline bool dns_joker_negative_scalar(
    instance* inst,
    double* state,
    lrandom* scratch
) {
    return dns_random_scalar(inst, state, scratch) > 0.997;
}

inline bool dns_index_locked(int index, ulong lockedLow, ulong lockedHigh) {
    int bit = index - 1;
    if (bit < 64) return (lockedLow >> bit) & 1UL;
    return (lockedHigh >> (bit - 64)) & 1UL;
}

inline int dns_shop_randindex_scalar(
    instance* inst,
    double* state,
    lrandom* scratch,
    rtype rngType,
    int ante,
    int itemCount,
    ulong lockedLow,
    ulong lockedHigh
) {
    *scratch = randomseed(dns_rng_node_advance_scalar(inst, state));
    int index = (int)l_randint(scratch, 1, itemCount);
    if (!inst->params.showman &&
        dns_index_locked(index, lockedLow, lockedHigh)) {
        int resampleNum = 1;
        while (dns_index_locked(index, lockedLow, lockedHigh)) {
            index = (int)randint(inst,
                (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample},
                (__private int[]){rngType, S_Shop, ante, resampleNum},
                4, 1, itemCount);
            *scratch = inst->rng;
            resampleNum++;
        }
    }
    return index;
}

// ---------------------------------------------------------------------------
// CANDIDATE (exact). Bit-identical scores to deep_negative_shops.cl.
//
// 1. The staging chunk grows from 32 to DNS_CHUNK shop joker slots. At 32
//    slots an ante's uncommon pool gets only ~8 ordinals per flush and the
//    rare pool ~1.6, so the per-flush counts are dominated by their own
//    spread; at 128 they are ~32 and ~6.4.
// 2. Each identity pool's resample chain is drawn DEPTH-MAJOR:
//
//      before:  for ordinal: draw base; while locked: draw resample_1, _2, ...
//      after :  for ordinal: draw base                    (base node)
//               for depth:   for each still-locked ordinal, in ordinal order:
//                                draw resample_<depth>
//
// Exactness: every RNG node is an independent stream (its state is a
// pseudohash of its own name plus the seed), so only the order of draws
// WITHIN one node can matter. The base node is still consumed in ordinal
// order; node resample_<d> is still consumed by exactly the ordinals locked
// at every depth < d, in increasing ordinal order - which is also what the
// ordinal-major loop produces. Same argument the existing 32-slot
// rarity/edition staging already relies on.
//
// Why it should be faster on a 32-lane warp: the ordinal-major form costs
// sum_over_ordinals max_over_lanes(1 + resamples), and resamples are
// geometric (p_locked = 22/64 uncommon, 11/20 rare) so the max over 32 lanes
// is several times the mean. Depth-major costs
// sum_over_depths max_over_lanes(count), and those counts are binomial, so
// they concentrate. None of this is visible on a CPU OpenCL device.
// ---------------------------------------------------------------------------
#ifndef DNS_CHUNK
#define DNS_CHUNK 512   // shop joker slots staged before identities are drawn
// Measured on an RTX 5080 (344,064 seeds, register-capped build), against 128:
//   chunk  64 = 1.158x (worse)   256 = 0.903x   512 = 0.859x
// The curve had not saturated at 128. Larger is better because a bigger chunk
// gives each identity pool more ordinals per depth pass, so the depth-major
// resample chain's trip count concentrates instead of diverging across lanes.
// Not raised further yet: the staging masks are DNS_CHUNK bits wide, so at 1024
// the ~5 live masks need ~160 registers and would spill past the 128-register
// cap. The largest ante has ~660 joker cards, so 1024 would be one chunk per
// ante and is the most chunking can ever do -- see diag_dns_chunk1024.
#endif
#if DNS_CHUNK < 1
#error "DNS_CHUNK must be positive"
#endif
// Round up: a chunk of 32 still needs one word, and the mask's capacity is then
// >= DNS_CHUNK, which is all the no-overflow argument requires.
#define DNS_MASK_WORDS ((DNS_CHUNK + 63) / 64)

// A DNS_CHUNK-wide bitmask. Capacity equals the chunk size by construction, so
// an identity buffer can never overflow its chunk whatever DNS_CHUNK is set to.
// (This was a hard-coded {lo, hi} pair, which silently capped the chunk at 128.)
typedef struct DnsMask { ulong w[DNS_MASK_WORDS]; } dns_mask;
inline void dnsm_clear(dns_mask* m) {
    for (int i = 0; i < DNS_MASK_WORDS; i++) m->w[i] = 0UL;
}
inline void dnsm_set(dns_mask* m, int o) { m->w[o >> 6] |= 1UL << (o & 63); }
inline void dnsm_clr(dns_mask* m, int o) { m->w[o >> 6] &= ~(1UL << (o & 63)); }
inline bool dnsm_get(const dns_mask* m, int o) {
    return ((m->w[o >> 6] >> (o & 63)) & 1UL) != 0UL;
}
inline bool dnsm_any(const dns_mask* m) {
    ulong any = 0UL;
    for (int i = 0; i < DNS_MASK_WORDS; i++) any |= m->w[i];
    return any != 0UL;
}
inline int dnsm_pop(const dns_mask* m) {
    int n = 0;
    for (int i = 0; i < DNS_MASK_WORDS; i++) n += popcount(m->w[i]);
    return n;
}
inline int dnsm_pop_and(const dns_mask* a, const dns_mask* b) {
    int n = 0;
    for (int i = 0; i < DNS_MASK_WORDS; i++) n += popcount(a->w[i] & b->w[i]);
    return n;
}
inline int dnsm_pop_andnot(const dns_mask* a, const dns_mask* b) {
    int n = 0;
    for (int i = 0; i < DNS_MASK_WORDS; i++) n += popcount(a->w[i] & ~b->w[i]);
    return n;
}


// --- dns_sub ablation switch resolution ------------------------------------
// dns_flush_identities is shared by the uncommon and rare pools; the pool is
// passed as the compile-time-constant `uncommonPool` argument of an inline
// function, so these fold away completely in every build.
#if defined(DNS_SUB_UNCID_BASE) && defined(DNS_SUB_RAREID_BASE)
    #define DNS_SUB_ABL_BASE(u) (true)
#elif defined(DNS_SUB_UNCID_BASE)
    #define DNS_SUB_ABL_BASE(u) (u)
#elif defined(DNS_SUB_RAREID_BASE)
    #define DNS_SUB_ABL_BASE(u) (!(u))
#else
    #define DNS_SUB_ABL_BASE(u) (false)
#endif
#if defined(DNS_SUB_UNCID_RESAMPLE) && defined(DNS_SUB_RAREID_RESAMPLE)
    #define DNS_SUB_ABL_RESAMPLE(u) (true)
#elif defined(DNS_SUB_UNCID_RESAMPLE)
    #define DNS_SUB_ABL_RESAMPLE(u) (u)
#elif defined(DNS_SUB_RAREID_RESAMPLE)
    #define DNS_SUB_ABL_RESAMPLE(u) (!(u))
#else
    #define DNS_SUB_ABL_RESAMPLE(u) (false)
#endif

// Draw one shop joker identity from a pool.

// --- dns_cnt draw-counting instrumentation ---------------------------------
// Defined only by the filters/dns_cnt_*.cl fixtures. When DNS_CNT is off every
// macro below expands to nothing, so the dns_sub_* timing fixtures carry zero
// counting overhead.
#define DNS_CNT_CARDTYPE        0
#define DNS_CNT_RARITY          1
#define DNS_CNT_EDITION         2
#define DNS_CNT_UNCID_BASE      3
#define DNS_CNT_UNCID_RESAMPLE  4
#define DNS_CNT_RAREID_BASE     5
#define DNS_CNT_RAREID_RESAMPLE 6
#define DNS_CNT_PACKSEL         7
#define DNS_CNT_PACKCONTENTS    8
#define DNS_CNT_VOUCHERS        9
#define DNS_CNT_TAGS            10
#define DNS_CNT_N               11
#ifdef DNS_CNT
    #define DNS_CNT_PARAM  , __private ulong* dnsCnt
    #define DNS_CNT_ARG    , dnsCnt
    #define DNS_CNT_ADD(i) (dnsCnt[i]++)
#else
    #define DNS_CNT_PARAM
    #define DNS_CNT_ARG
    #define DNS_CNT_ADD(i) ((void)0)
#endif

#ifdef DNS_CNT
// EXACT replicas of lib/instance.cl randchoice_common, lib/functions.cl
// next_voucher and the filter's own dns_joker, built from the same lib
// primitives called in the same order, so the RNG stream is unchanged and the
// score is unchanged. They exist only to make lib-internal resample draws
// countable without editing lib/. HAND-SYNC HAZARD: if lib changes these must
// change too - filters/dns_cnt_selfcheck.cl exists to catch that.
item dns_cnt_randchoice_common(instance* inst, rtype rngType, rsrc src, int ante,
                               __constant item items[], int slot,
                               __private ulong* dnsCnt) {
    item i = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante},
                        (__private int[]){rngType, src, ante}, 3, items);
    dnsCnt[slot]++;
    if (!inst->params.showman && i_locked(inst, i)) {
        int resampleNum = 1;
        while (i_locked(inst, i)) {
            i = randchoice(inst,
                (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample},
                (__private int[]){rngType, src, ante, resampleNum}, 4, items);
            dnsCnt[slot]++;
            resampleNum++;
        }
    }
    return i;
}
item dns_cnt_next_voucher(instance* inst, int ante, __private ulong* dnsCnt) {
    item i = randchoice(inst, (__private ntype[]){N_Type, N_Ante},
                        (__private int[]){R_Voucher, ante}, 2, VOUCHERS);
    dnsCnt[DNS_CNT_VOUCHERS]++;
    if (i_locked(inst, i)) {
        int resampleNum = 1;
        while (i_locked(inst, i)) {
            i = randchoice(inst, (__private ntype[]){N_Type, N_Ante, N_Resample},
                           (__private int[]){R_Voucher, ante, resampleNum}, 3, VOUCHERS);
            dnsCnt[DNS_CNT_VOUCHERS]++;
            resampleNum++;
        }
    }
    return i;
}
inline item dns_cnt_next_tag(instance* inst, int ante, __private ulong* dnsCnt) {
    return dns_cnt_randchoice_common(inst, R_Tags, S_Null, ante, TAGS,
                                     DNS_CNT_TAGS, dnsCnt);
}
// next_joker_rarity and next_joker_edition are exactly one draw each for
// S_Buffoon (neither hits an early return for that source).
inline void dns_cnt_joker(instance* inst, rsrc src, int ante, dns_counts* c,
                          item* drawn, __private ulong* dnsCnt) {
    rarity r = next_joker_rarity(inst, src, ante);
    dnsCnt[DNS_CNT_PACKCONTENTS]++;
    item joker;
    if (r == Rarity_Rare)
        joker = dns_cnt_randchoice_common(inst, R_Joker_Rare, src, ante,
                                          RARE_JOKERS, DNS_CNT_PACKCONTENTS, dnsCnt);
    else if (r == Rarity_Uncommon)
        joker = dns_cnt_randchoice_common(inst, R_Joker_Uncommon, src, ante,
                                          UNCOMMON_JOKERS, DNS_CNT_PACKCONTENTS, dnsCnt);
    else
        joker = dns_cnt_randchoice_common(inst, R_Joker_Common, src, ante,
                                          COMMON_JOKERS, DNS_CNT_PACKCONTENTS, dnsCnt);
    item edition = next_joker_edition(inst, src, ante);
    dnsCnt[DNS_CNT_PACKCONTENTS]++;
    *drawn = joker;
    if (joker == Diet_Cola) { c->other++; return; }
    if (edition != Negative) return;
    if (joker == Brainstorm || joker == Blueprint) c->copy++;
    else if (r == Rarity_Uncommon) c->uncommon++;
    else c->other++;
}
// Pack `v` into `width` bits at `shift`; sets `ovf` if it does not fit.
inline ulong dns_cnt_field(ulong v, int shift, int width, bool* ovf) {
    if (v >= (1UL << width)) { *ovf = true; return 0UL; }
    return v << shift;
}
#endif

// Draw `n` identities from one shop rarity pool, depth-major.
// `neg` carries each ordinal's Negative-edition bit; `specialA/B` are the
// indices that score specially (Diet Cola for uncommons, Blueprint and
// Brainstorm for rares).
inline void dns_flush_identities(
    instance* inst, double* state, lrandom* scratch,
    rtype rngType, int ante, int n, const dns_mask* neg, int itemCount,
    ulong lockedLow, ulong lockedHigh,
    int specialA, int specialB, bool uncommonPool, dns_counts* c
    DNS_CNT_PARAM
) {
    dns_mask locked, special;
    dnsm_clear(&locked); dnsm_clear(&special);
    for (int o = 0; o < n; o++) {
        int index;
        if (DNS_SUB_ABL_BASE(uncommonPool)) {
            // Ablated: no RNG draw. Sweep the pool so the resample chain that
            // follows still fires at very close to the real locked fraction
            // and the special index is still hit at 1/itemCount.
            index = (o % itemCount) + 1;
        } else {
            *scratch = randomseed(dns_rng_node_advance_scalar(inst, state));
            index = (int)l_randint(scratch, 1, itemCount);
            DNS_CNT_ADD(uncommonPool ? DNS_CNT_UNCID_BASE : DNS_CNT_RAREID_BASE);
        }
        if (index == specialA || index == specialB) dnsm_set(&special, o);
        if (dns_index_locked(index, lockedLow, lockedHigh)) dnsm_set(&locked, o);
    }
    // Ablated RESAMPLE: every index is treated as unlocked, so the whole
    // depth-major while-chain (and its resample nodes) disappears. The base
    // draw above is untouched.
    if (!inst->params.showman && !DNS_SUB_ABL_RESAMPLE(uncommonPool)) {
        for (int depth = 1; dnsm_any(&locked); depth++) {
            rng_node_id nd = rng_node_resolve(inst,
                (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample},
                (__private int[]){rngType, S_Shop, ante, depth}, 4);
            double st = inst->rngCache.nodes[nd].rngState;
            dns_mask next; dnsm_clear(&next);
            // set bits in increasing ordinal order: low word first
            for (int word = 0; word < DNS_MASK_WORDS; word++) {
                ulong m = locked.w[word];
                int off = word * 64;
                while (m != 0UL) {
                    ulong low = m & (~m + 1UL);
                    int o = off + (int)(63UL - clz(low));
                    m ^= low;
                    *scratch = randomseed(dns_rng_node_advance_scalar(inst, &st));
                    int index = (int)l_randint(scratch, 1, itemCount);
                    DNS_CNT_ADD(uncommonPool ? DNS_CNT_UNCID_RESAMPLE
                                             : DNS_CNT_RAREID_RESAMPLE);
                    if (index == specialA || index == specialB) dnsm_set(&special, o);
                    else dnsm_clr(&special, o);
                    if (dns_index_locked(index, lockedLow, lockedHigh)) dnsm_set(&next, o);
                }
            }
            inst->rngCache.nodes[nd].rngState = st;
            locked = next;
        }
    }
    if (uncommonPool) {
        // Diet Cola scores as `other` whatever its edition; any other uncommon
        // scores only when Negative.
        c->other    += dnsm_pop(&special);
        c->uncommon += dnsm_pop_andnot(neg, &special);
    } else {
        c->copy  += dnsm_pop_and(neg, &special);
        c->other += dnsm_pop_andnot(neg, &special);
    }
}

// Classify one joker after its rarity draw: identity where needed, then edition.
inline void dns_joker_from_rarity(instance* inst, rsrc src, int ante, rarity r, dns_counts* c, item* drawn) {
    item joker;
    if (r == Rarity_Rare) joker = randchoice_common(inst, R_Joker_Rare, src, ante, RARE_JOKERS);
    else if (r == Rarity_Uncommon) joker = randchoice_common(inst, R_Joker_Uncommon, src, ante, UNCOMMON_JOKERS);
    else joker = randchoice_common(inst, R_Joker_Common, src, ante, COMMON_JOKERS);
    item edition = next_joker_edition(inst, src, ante);
    *drawn = joker;
    if (joker == Diet_Cola) { c->other++; return; }
    if (edition != Negative) return;
    if (joker == Brainstorm || joker == Blueprint) c->copy++;
    else if (r == Rarity_Uncommon) c->uncommon++;
    else c->other++;
}

inline void dns_joker(instance* inst, rsrc src, int ante, dns_counts* c, item* drawn) {
    dns_joker_from_rarity(inst, src, ante, next_joker_rarity(inst, src, ante), c, drawn);
}

// DIAG_BALLAST_KB adds N KB of otherwise-unused private memory to the kernel
// frame, to measure how per-work-item footprint alone affects throughput. It
// changes nothing else: the same draws, the same ALU, the same cache traffic.
// The array is volatile and is written and read at two seed-dependent indices
// the compiler cannot bound, so it cannot be scalarised away; the value read is
// always the value written, so the score stays bit-identical to a
// DIAG_BALLAST_KB=0 build. Diagnostic only - see tests/diagnostics.json.
//
// NOTE: on an RTX 5080 this sweep was NOT readable as a footprint measurement
// until -cl-nv-maxrregcount pinned the register count. Unpinned, any source
// perturbation moves the kernel between 12/14/15/16 resident warps and swamps
// the footprint effect: 1 KB and 4 KB of ballast measured identically (0.933x),
// as did 2 KB and 8 KB (0.878x). Always pin registers when running this.
#ifndef DIAG_BALLAST_KB
#define DIAG_BALLAST_KB 0
#endif
#define DIAG_BALLAST_WORDS (DIAG_BALLAST_KB * 128)
#define DIAG_BALLAST_MAGIC 0x5A5A5A5A5A5A5A5AUL

long filter(instance* inst) {
#if DIAG_BALLAST_KB > 0
    volatile ulong diag_ballast[DIAG_BALLAST_WORDS];
    uint diag_bi = (uint)(inst->seed.data[0] * 31UL + inst->seed.data[1]) % (uint)DIAG_BALLAST_WORDS;
    uint diag_bj = (uint)(inst->seed.data[2] * 17UL + inst->seed.data[3] + 1UL) % (uint)DIAG_BALLAST_WORDS;
    diag_ballast[diag_bi] = DIAG_BALLAST_MAGIC;
    diag_ballast[diag_bj] = DIAG_BALLAST_MAGIC;
#endif
    for (int i = 0; i < (int)(sizeof(DNS_UPGRADE_VOUCHERS) / sizeof(item)); i++) i_lock(inst, DNS_UPGRADE_VOUCHERS[i]);
    DNS_APPLY_LOCKS(DNS_LOCKED_COMMONS, i_lock)
    DNS_APPLY_LOCKS(DNS_LOCKED_UNCOMMONS, i_lock)
    DNS_APPLY_LOCKS(DNS_LOCKED_RARES, i_lock)
    DNS_APPLY_LOCKS(DNS_UNLOCKED_COMMONS, i_unlock)
    DNS_APPLY_LOCKS(DNS_UNLOCKED_UNCOMMONS, i_unlock)
    DNS_APPLY_LOCKS(DNS_UNLOCKED_RARES, i_unlock)

    int uncommonItemCount = (int)UNCOMMON_JOKERS[0];
    int rareItemCount = (int)RARE_JOKERS[0];
    ulong uncommonLockedLow = 0UL, uncommonLockedHigh = 0UL;
    ulong rareLocked = 0UL;
    int dietColaIndex = -1, blueprintIndex = -1, brainstormIndex = -1;
    for (int index = 1; index <= uncommonItemCount; index++) {
        item joker = UNCOMMON_JOKERS[index];
        int bit = index - 1;
        if (i_locked(inst, joker)) {
            if (bit < 64) uncommonLockedLow |= 1UL << bit;
            else uncommonLockedHigh |= 1UL << (bit - 64);
        }
        if (joker == Diet_Cola) dietColaIndex = index;
    }
    for (int index = 1; index <= rareItemCount; index++) {
        item joker = RARE_JOKERS[index];
        if (i_locked(inst, joker)) rareLocked |= 1UL << (index - 1);
        if (joker == Blueprint) blueprintIndex = index;
        if (joker == Brainstorm) brainstormIndex = index;
    }

    shop shopInstance = get_shop_instance(inst);
    double totalRate = get_total_rate(shopInstance);
    bool overstock = false, overstockPlus = false;
    dns_counts c = {0, 0, 0};
    int firstTagNeg = 0, secondTagNeg = 0;
    int dnsSubPackIdx = 0;   // dns_sub_packsel only; unused otherwise
#ifdef DNS_CNT
    ulong dnsCnt[DNS_CNT_N];
    for (int i = 0; i < DNS_CNT_N; i++) dnsCnt[i] = 0UL;
#endif

    for (int ante = 1; ante <= DNS_LAST_ANTE; ante++) {
#if DNS_ANTE_LOCAL_CACHE
        // Every reachable node in this version is ante-keyed. Keep persistent
        // cache flags and seed-hash state; only discard unreachable node slots.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
#endif
#ifdef DNS_SUB_VOUCHERS
        // Ablated: no voucher draw and no resamples. CAVEAT, stated plainly:
        // this also removes early-Overstock frame growth, so on the minority
        // of seeds that see Overstock before ante 12 the downstream shop is
        // smaller than baseline. Hone is not in DNS_BOUGHT_VOUCHERS, so
        // nothing activates.
        item v = Hone;
#else
  #ifdef DNS_CNT
        item v = dns_cnt_next_voucher(inst, ante, dnsCnt);
  #else
        item v = next_voucher(inst, ante);
  #endif
#endif
        for (int i = 0; i < (int)(sizeof(DNS_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
            if (DNS_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante < DNS_FIRST_ANTE) continue;

#ifdef DNS_SUB_TAGS
        // Ablated: both per-ante tag draws replaced by a constant non-Negative
        // tag, so firstTagNeg / secondTagNeg stay 0.
        if (Uncommon_Tag == Negative_Tag) firstTagNeg++;
        if (Uncommon_Tag == Negative_Tag) secondTagNeg++;
#else
  #ifdef DNS_CNT
        if (dns_cnt_next_tag(inst, ante, dnsCnt) == Negative_Tag) firstTagNeg++;
        if (dns_cnt_next_tag(inst, ante, dnsCnt) == Negative_Tag) secondTagNeg++;
  #else
        if (next_tag(inst, ante) == Negative_Tag) firstTagNeg++;
        if (next_tag(inst, ante) == Negative_Tag) secondTagNeg++;
  #endif
#endif

        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
        int cards = dns_frames(ante) * frameSize;
        // Initialised (the shipped filter leaves it dead until the card-type
        // loop writes it) so an ablated build never reads uninitialised state.
        lrandom shopRng = inst->rng;
        int jokerCards;
#ifdef DNS_SUB_CARDTYPE
        // Ablated: the per-card poll and its node are gone. jokerCards is the
        // exact expectation (jokerRate 20 of totalRate 28), so every
        // downstream stream still runs the same number of times.
        jokerCards = cards * 20 / 28;
#else
        rng_node_id cardTypeNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante},
            (__private int[]){R_Card_Type, ante}, 2);
        double cardTypeState = inst->rngCache.nodes[cardTypeNode].rngState;
        // Raw shop streams have no frame-local locks, so count card types first
        // and consume the independent Joker streams densely afterward.
        jokerCards = 0;
        for (int i = 0; i < cards; i++) {
            double card_type = dns_random_scalar(inst,
                &cardTypeState, &shopRng) * totalRate;
            jokerCards += get_item_type(shopInstance, card_type) == ItemType_Joker;
            DNS_CNT_ADD(DNS_CNT_CARDTYPE);
        }
        inst->rngCache.nodes[cardTypeNode].rngState = cardTypeState;
#endif
        if (jokerCards > 0) {
#ifndef DNS_SUB_RARITY
            rng_node_id shopRarityNode = rng_node_resolve(inst,
                (__private ntype[]){N_Type, N_Ante, N_Source},
                (__private int[]){R_Joker_Rarity, ante, S_Shop}, 3);
            double shopRarityState =
                inst->rngCache.nodes[shopRarityNode].rngState;
#endif
#ifndef DNS_SUB_EDITION
            rng_node_id shopEditionNode = rng_node_resolve(inst,
                (__private ntype[]){N_Type, N_Source, N_Ante},
                (__private int[]){R_Joker_Edition, S_Shop, ante}, 3);
            double shopEditionState =
                inst->rngCache.nodes[shopEditionNode].rngState;
#endif
            rng_node_id shopUncommonNode = RNG_NODE_INVALID;
            rng_node_id shopRareNode = RNG_NODE_INVALID;
            double shopUncommonState = 0, shopRareState = 0;

            // Stage rarity and edition in DNS_CHUNK-slot chunks, then draw each
            // identity pool depth-major. Every lane flushes at the same chunk
            // boundary, so the flushes stay warp-aligned.
            for (int base = 0; base < jokerCards; base += DNS_CHUNK) {
                int chunkSize = min(DNS_CHUNK, jokerCards - base);
                dns_mask uncommonNegative, rareNegative;
                dnsm_clear(&uncommonNegative); dnsm_clear(&rareNegative);
                int uncommonCount = 0, rareCount = 0;

                for (int slot = 0; slot < chunkSize; slot++) {
#ifdef DNS_SUB_RARITY
                    // Ablated: no poll. Deterministic 20-slot cycle keeps the
                    // real 5% rare / 25% uncommon / 70% common split, so the
                    // identity streams below still get the same volume.
                    int _dnsRs = (base + slot) % 20;
                    rarity r = (_dnsRs == 0)  ? Rarity_Rare
                             : (_dnsRs < 6)   ? Rarity_Uncommon
                                              : Rarity_Common;
#else
                    rarity r = dns_joker_rarity_scalar(inst,
                        &shopRarityState, &shopRng);
                    DNS_CNT_ADD(DNS_CNT_RARITY);
#endif
#ifdef DNS_SUB_EDITION
                    // Ablated: no poll. Negative is ~0.3% and gates no further
                    // draws, so downstream work is unchanged; only the score is.
                    bool negative = false;
#else
                    bool negative = dns_joker_negative_scalar(inst,
                        &shopEditionState, &shopRng);
                    DNS_CNT_ADD(DNS_CNT_EDITION);
#endif

                    if (r == Rarity_Common) {
                        c.other += negative;
                    } else if (r == Rarity_Uncommon) {
                        if (negative) dnsm_set(&uncommonNegative, uncommonCount);
                        uncommonCount++;
                    } else {
                        if (negative) dnsm_set(&rareNegative, rareCount);
                        rareCount++;
                    }
                }

                if (uncommonCount > 0) {
                    if (shopUncommonNode == RNG_NODE_INVALID) {
                        shopUncommonNode = rng_node_resolve(inst,
                            (__private ntype[]){N_Type, N_Source, N_Ante},
                            (__private int[]){R_Joker_Uncommon, S_Shop, ante}, 3);
                        shopUncommonState =
                            inst->rngCache.nodes[shopUncommonNode].rngState;
                    }
                    dns_flush_identities(inst, &shopUncommonState, &shopRng,
                        R_Joker_Uncommon, ante, uncommonCount, &uncommonNegative,
                        uncommonItemCount, uncommonLockedLow, uncommonLockedHigh,
                        dietColaIndex, dietColaIndex, true, &c DNS_CNT_ARG);
                }

                if (rareCount > 0) {
                    if (shopRareNode == RNG_NODE_INVALID) {
                        shopRareNode = rng_node_resolve(inst,
                            (__private ntype[]){N_Type, N_Source, N_Ante},
                            (__private int[]){R_Joker_Rare, S_Shop, ante}, 3);
                        shopRareState = inst->rngCache.nodes[shopRareNode].rngState;
                    }
                    dns_flush_identities(inst, &shopRareState, &shopRng,
                        R_Joker_Rare, ante, rareCount, &rareNegative,
                        rareItemCount, rareLocked, 0UL,
                        blueprintIndex, brainstormIndex, false, &c DNS_CNT_ARG);
                }
            }
#ifndef DNS_SUB_RARITY
            inst->rngCache.nodes[shopRarityNode].rngState = shopRarityState;
#endif
#ifndef DNS_SUB_EDITION
            inst->rngCache.nodes[shopEditionNode].rngState = shopEditionState;
#endif
            if (shopUncommonNode != RNG_NODE_INVALID)
                inst->rngCache.nodes[shopUncommonNode].rngState =
                    shopUncommonState;
            if (shopRareNode != RNG_NODE_INVALID)
                inst->rngCache.nodes[shopRareNode].rngState = shopRareState;
        }
        inst->rng = shopRng;
        for (int p = 0; p < DNS_PACKS; p++) {
#ifdef DNS_SUB_PACKSEL
            // Ablated: no weighted pack draw. A deterministic cycle reproduces
            // the real Buffoon share (1.95/22.42 = 8.7%, here 1/12 = 8.3%) and
            // the 8:4:1 plain/Jumbo/Mega split (mean size 2.77, same as PACKS),
            // so pack-contents volume is preserved.
            item _packItem;
            int _pk = dnsSubPackIdx++;
            if (_pk % 12 != 0) {
                _packItem = Arcana_Pack;
            } else {
                int _b = (_pk / 12) % 13;
                _packItem = (_b < 8) ? Buffoon_Pack
                          : (_b < 12) ? Jumbo_Buffoon_Pack : Mega_Buffoon_Pack;
            }
            pack _pack = pack_info(_packItem);
#else
            pack _pack = pack_info(next_pack(inst, ante));
            // ante >= DNS_FIRST_ANTE (3) here, so next_pack never takes the
            // free first-Buffoon early return: exactly one weighted draw.
            DNS_CNT_ADD(DNS_CNT_PACKSEL);
#endif
            if (_pack.type != Buffoon_Pack) continue;
            item drawn[5];
            for (int j = 0; j < _pack.size; j++) {
#ifdef DNS_SUB_PACKCONTENTS
                // Ablated: the pack card's rarity, edition and identity draws
                // (and any identity resamples) are gone; a constant identity
                // keeps the temporary within-pack lock/unlock machinery alive.
                drawn[j] = UNCOMMON_JOKERS[(j % uncommonItemCount) + 1];
#else
  #ifdef DNS_CNT
                dns_cnt_joker(inst, S_Buffoon, ante, &c, &drawn[j], dnsCnt);
  #else
                dns_joker(inst, S_Buffoon, ante, &c, &drawn[j]);
  #endif
#endif
                if (!inst->params.showman) i_lock(inst, drawn[j]); // temporary reroll, as buffoon_pack does
            }
            for (int j = 0; j < _pack.size; j++) i_unlock(inst, drawn[j]);
        }
    }
#if DIAG_BALLAST_KB > 0
    // Always 0: diag_bj was written with the magic above. Keeps the ballast
    // live across the whole ante loop without perturbing the score.
    long diag_extra = (diag_ballast[diag_bj] == DIAG_BALLAST_MAGIC) ? 0L : 1L;
#else
    long diag_extra = 0L;
#endif
#if defined(DNS_CNT_DRAWS) || defined(DNS_CNT_DRAWS2)
    {
        bool ovf = false;
        ulong packed = 0UL;
  #ifdef DNS_CNT_DRAWS
        // dns_cnt_draws packing, low bit first:
        //   [ 0..14] 15b shop card-type draws        (hard max 20964)
        //   [15..29] 15b shop joker rarity draws     (hard max = card-type)
        //   [30..42] 13b uncommon identity BASE
        //   [43..55] 13b uncommon identity RESAMPLE
        //   [56]      1b edition draws == rarity draws (must read 1)
        //   [57..62]  6b reserved, always 0
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_CARDTYPE],       0, 15, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_RARITY],        15, 15, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_UNCID_BASE],    30, 13, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_UNCID_RESAMPLE],43, 13, &ovf);
        if (dnsCnt[DNS_CNT_EDITION] == dnsCnt[DNS_CNT_RARITY]) packed |= 1UL << 56;
  #else
        // dns_cnt_draws2 packing, low bit first:
        //   [ 0..10] 11b rare identity BASE
        //   [11..22] 12b rare identity RESAMPLE
        //   [23..35] 13b buffoon pack CONTENTS (rarity+identity+resamples+edition)
        //   [36..44]  9b pack SELECTION (next_pack; exactly 216 at defaults)
        //   [45..53]  9b VOUCHER draws incl. resamples
        //   [54..62]  9b TAG draws incl. resamples
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_RAREID_BASE],     0, 11, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_RAREID_RESAMPLE],11, 12, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_PACKCONTENTS],   23, 13, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_PACKSEL],        36,  9, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_VOUCHERS],       45,  9, &ovf);
        packed |= dns_cnt_field(dnsCnt[DNS_CNT_TAGS],           54,  9, &ovf);
  #endif
        // A field that did not fit poisons the whole seed with -1 rather than
        // silently truncating.
        return ovf ? -1L : (long)packed;
    }
#endif
    return (long)c.copy * 1000000000000L + (long)c.uncommon * 1000000000L + (long)c.other * 1000000L
         + (long)firstTagNeg * 1000L + (long)secondTagNeg + diag_extra;
}
