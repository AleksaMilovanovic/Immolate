// =========================================================================
// DIAGNOSTIC FIXTURE - PRODUCES DELIBERATELY WRONG SCORES.
// Never wire this into tests/golden/. Part of the DNS benchmark pack.
// DIVERGENCE PROBE.
//
// WHAT IS FORCED UNIFORM: the shop frame size, and through it the per-ante
// card count. Overstock / Overstock Plus sightings no longer widen the
// frame, so frame size is a pure function of the ante and every seed walks
// exactly the same 17,910 shop cards.
//
// CONSTANT: 17,910 cards/seed, derived in the body comment from the frame
// schedule. Measured seeds average ~18,796 cards (13,426 joker cards at the
// 5/7 shop joker share), so this fixture removes ~4.7% of draws along with
// all of the frame-size spread - the draw-count change is small enough that
// a large speedup is attributable to uniformity, not to less work.
//
// NOTE: filters/diag_dns_uniform_frames.cl is the same idea but is a STALE
// copy - it predates this session's rewrite and still carries the old
// 32-slot ordinal-major staging and the 128-bit mask pair. It is not
// comparable to the current shipped filter; use this one.
//
// PREDICTION: 0.80x-0.95x. Draws fall 4.7%, so anything below ~0.95x is
// divergence rather than work. The Overstock split is bimodal (a seed either
// sees it early or does not), which is the worst case for a warp: two stable
// populations of lanes with a ~50% card-count gap. A ratio near 0.95x means
// the chunked staging already absorbs that; near 0.80x means seeds should be
// bucketed by early-Overstock before dispatch.
// =========================================================================
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

// Draw `n` identities from one shop rarity pool, depth-major.
// `neg` carries each ordinal's Negative-edition bit; `specialA/B` are the
// indices that score specially (Diet Cola for uncommons, Blueprint and
// Brainstorm for rares).
inline void dns_flush_identities(
    instance* inst, double* state, lrandom* scratch,
    rtype rngType, int ante, int n, const dns_mask* neg, int itemCount,
    ulong lockedLow, ulong lockedHigh,
    int specialA, int specialB, bool uncommonPool, dns_counts* c
) {
    dns_mask locked, special;
    dnsm_clear(&locked); dnsm_clear(&special);
    for (int o = 0; o < n; o++) {
        *scratch = randomseed(dns_rng_node_advance_scalar(inst, state));
        int index = (int)l_randint(scratch, 1, itemCount);
        if (index == specialA || index == specialB) dnsm_set(&special, o);
        if (dns_index_locked(index, lockedLow, lockedHigh)) dnsm_set(&locked, o);
    }
    if (!inst->params.showman) {
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

    for (int ante = 1; ante <= DNS_LAST_ANTE; ante++) {
#if DNS_ANTE_LOCAL_CACHE
        // Every reachable node in this version is ante-keyed. Keep persistent
        // cache flags and seed-hash state; only discard unreachable node slots.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
#endif
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(DNS_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
            if (DNS_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante < DNS_FIRST_ANTE) continue;

        if (next_tag(inst, ante) == Negative_Tag) firstTagNeg++;
        if (next_tag(inst, ante) == Negative_Tag) secondTagNeg++;

        // DIVERGENCE PROBE: frame size depends on the ante only; the Overstock
        // and Overstock Plus sightings are ignored. Every seed then does the
        // same 17,910 shop cards, so the card-type loop, the staging loop and
        // the chunk count all have identical trip counts in every lane.
        //   frames: ante 3 = 30; 4-10 = 80+3(a-4); 11-15 = 100+4(a-11);
        //           16-38 = 116+5(a-15)        -> 5,241 frames over antes 3-38
        //   size 2 for antes 3-11   (753 frames)   =  1,506 cards
        //   size 3 for antes 12-23  (1,548 frames) =  4,644 cards
        //   size 4 for antes 24-38  (2,940 frames) = 11,760 cards
        //                                    total = 17,910 cards
        int frameSize = 2;
        if (ante >= 12) frameSize = 3;
        if (ante >= 24) frameSize = 4;
        int cards = dns_frames(ante) * frameSize;
        rng_node_id cardTypeNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante},
            (__private int[]){R_Card_Type, ante}, 2);
        double cardTypeState = inst->rngCache.nodes[cardTypeNode].rngState;
        lrandom shopRng;
        // Raw shop streams have no frame-local locks, so count card types first
        // and consume the independent Joker streams densely afterward.
        int jokerCards = 0;
        for (int i = 0; i < cards; i++) {
            double card_type = dns_random_scalar(inst,
                &cardTypeState, &shopRng) * totalRate;
            jokerCards += get_item_type(shopInstance, card_type) == ItemType_Joker;
        }
        inst->rngCache.nodes[cardTypeNode].rngState = cardTypeState;
        if (jokerCards > 0) {
            rng_node_id shopRarityNode = rng_node_resolve(inst,
                (__private ntype[]){N_Type, N_Ante, N_Source},
                (__private int[]){R_Joker_Rarity, ante, S_Shop}, 3);
            rng_node_id shopEditionNode = rng_node_resolve(inst,
                (__private ntype[]){N_Type, N_Source, N_Ante},
                (__private int[]){R_Joker_Edition, S_Shop, ante}, 3);
            double shopRarityState =
                inst->rngCache.nodes[shopRarityNode].rngState;
            double shopEditionState =
                inst->rngCache.nodes[shopEditionNode].rngState;
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
                    rarity r = dns_joker_rarity_scalar(inst,
                        &shopRarityState, &shopRng);
                    bool negative = dns_joker_negative_scalar(inst,
                        &shopEditionState, &shopRng);

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
                        dietColaIndex, dietColaIndex, true, &c);
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
                        blueprintIndex, brainstormIndex, false, &c);
                }
            }
            inst->rngCache.nodes[shopRarityNode].rngState = shopRarityState;
            inst->rngCache.nodes[shopEditionNode].rngState = shopEditionState;
            if (shopUncommonNode != RNG_NODE_INVALID)
                inst->rngCache.nodes[shopUncommonNode].rngState =
                    shopUncommonState;
            if (shopRareNode != RNG_NODE_INVALID)
                inst->rngCache.nodes[shopRareNode].rngState = shopRareState;
        }
        inst->rng = shopRng;
        for (int p = 0; p < DNS_PACKS; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            if (_pack.type != Buffoon_Pack) continue;
            item drawn[5];
            for (int j = 0; j < _pack.size; j++) {
                dns_joker(inst, S_Buffoon, ante, &c, &drawn[j]);
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
    return (long)c.copy * 1000000000000L + (long)c.uncommon * 1000000000L + (long)c.other * 1000000L
         + (long)firstTagNeg * 1000L + (long)secondTagNeg + diag_extra;
}
