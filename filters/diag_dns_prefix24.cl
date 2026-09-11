// ===========================================================================
// DIAGNOSTIC ABLATION - PRODUCES DELIBERATELY WRONG SCORES.
// Part of the DNS benchmark pack. Never wire this into correctness goldens.
// PREFILTER PROTOTYPE. Runs the voucher chain for every ante but the shop,
// pack and tag work only for antes 3..24. The returned score is the exact
// PREFIX score, which is a LOWER bound on the full score and therefore
// cannot be used to reject a seed without false negatives - see the
// report. Shipped to measure prefix COST as a fraction of the full run.
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
#if DNS_ANTE_LOCAL_CACHE
    #define CACHE_SIZE 256
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

long filter(instance* inst) {
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
        if (ante > 24 && ante >= DNS_FIRST_ANTE) { // PREFIX PROTOTYPE
            // keep the voucher chain exact, drop all shop/pack/tag work
            item _v = next_voucher(inst, ante);
            for (int i = 0; i < (int)(sizeof(DNS_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
                if (DNS_BOUGHT_VOUCHERS[i] == _v) { activate_voucher(inst, _v); break; }
            }
            continue;
        }
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

        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
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

            // Stage rarity and edition in warp-sized chunks, then consume each
            // identity stream densely while preserving its ordinal draw order.
            for (int base = 0; base < jokerCards; base += 32) {
                int chunkSize = min(32, jokerCards - base);
                uint uncommonNegative = 0u, rareNegative = 0u;
                int uncommonCount = 0, rareCount = 0;

                for (int slot = 0; slot < chunkSize; slot++) {
                    rarity r = dns_joker_rarity_scalar(inst,
                        &shopRarityState, &shopRng);
                    bool negative = dns_joker_negative_scalar(inst,
                        &shopEditionState, &shopRng);

                    if (r == Rarity_Common) {
                        c.other += negative;
                    } else if (r == Rarity_Uncommon) {
                        uncommonNegative |= (uint)negative << uncommonCount;
                        uncommonCount++;
                    } else {
                        rareNegative |= (uint)negative << rareCount;
                        rareCount++;
                    }
                }

                if (uncommonCount > 0 && shopUncommonNode == RNG_NODE_INVALID) {
                    shopUncommonNode = rng_node_resolve(inst,
                        (__private ntype[]){N_Type, N_Source, N_Ante},
                        (__private int[]){R_Joker_Uncommon, S_Shop, ante}, 3);
                    shopUncommonState =
                        inst->rngCache.nodes[shopUncommonNode].rngState;
                }
                for (int ordinal = 0; ordinal < uncommonCount; ordinal++) {
                    int jokerIndex = dns_shop_randindex_scalar(inst,
                        &shopUncommonState, &shopRng,
                        R_Joker_Uncommon, ante, uncommonItemCount,
                        uncommonLockedLow, uncommonLockedHigh);
                    if (jokerIndex == dietColaIndex) {
                        c.other++;
                    } else if ((uncommonNegative >> ordinal) & 1u) {
                        c.uncommon++;
                    }
                }

                if (rareCount > 0 && shopRareNode == RNG_NODE_INVALID) {
                    shopRareNode = rng_node_resolve(inst,
                        (__private ntype[]){N_Type, N_Source, N_Ante},
                        (__private int[]){R_Joker_Rare, S_Shop, ante}, 3);
                    shopRareState = inst->rngCache.nodes[shopRareNode].rngState;
                }
                for (int ordinal = 0; ordinal < rareCount; ordinal++) {
                    int jokerIndex = dns_shop_randindex_scalar(inst,
                        &shopRareState, &shopRng, R_Joker_Rare, ante,
                        rareItemCount, rareLocked, 0UL);
                    if ((rareNegative >> ordinal) & 1u) {
                        if (jokerIndex == brainstormIndex ||
                            jokerIndex == blueprintIndex) c.copy++;
                        else c.other++;
                    }
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
    return (long)c.copy * 1000000000000L + (long)c.uncommon * 1000000000L + (long)c.other * 1000000L
         + (long)firstTagNeg * 1000L + (long)secondTagNeg;
}
