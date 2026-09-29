// Counts copy jokers -- Blueprint and Brainstorm -- across the shop queues of
// antes DCS_FIRST_ANTE..DCS_LAST_ANTE, split by edition.
//
//   score = negative * 10000 + base
//
// where `negative` is copy jokers rolled Negative and `base` is copy jokers
// with no edition at all (Foil, Holographic and Polychrome ones are counted as
// neither: they cost a joker slot and cannot take a Negative Tag, so they are
// no use to a copy-chain build). Both fields are capped at 9999, which a 38-ante
// walk comes nowhere near -- the base count runs to roughly 130.
//
// Same shop queue as deep_negative_shops and analyze_naneinf_negatives: same
// frame counts, same frame sizes, same voucher handling, same joker lock lists,
// so the numbers line up with theirs. See the deep_negative_shops header for
// the reasoning behind any of it.
//
// NOT counted: Buffoon packs. DNS and ANN both walk them, this does not -- the
// ask was the shop frames, and skipping packs is most of why this is cheap.
//
// Cheap because it draws the minimum: a card-type poll per shop card, then a
// rarity poll and an edition poll per joker, and a joker's IDENTITY only when
// the rarity poll says Rare (~5% of jokers). Both copy jokers are Rare, so a
// Common or Uncommon slot can never be one and its identity is never worth
// drawing. The three hot streams are consumed straight off their own node's
// state, as deep_negative_shops does, instead of through the cached lib path.
//
// The Rare identity node is the only one that resamples, and with 8 of 19 rares
// unlocked those chains are short, so the default node cache is ample.
#define CACHE_SIZE 256
#include "lib/immolate.cl"

#ifndef DCS_FIRST_ANTE
#define DCS_FIRST_ANTE 3
#endif
#ifndef DCS_LAST_ANTE
#define DCS_LAST_ANTE 38
#endif

// Same lists as deep_negative_shops: a fresh profile's locked jokers, with the
// two copy jokers unlocked because the filter is looking for them.
__constant item DCS_LOCKED_COMMONS[] = {
    Golden_Ticket, Swashbuckler, Hanging_Chad, Shoot_the_Moon
};
__constant item DCS_LOCKED_UNCOMMONS[] = {
    Mr_Bones, Acrobat, Sock_and_Buskin, Troubadour, Certificate, Smeared_Joker, Throwback,
    Rough_Gem, Bloodstone, Arrowhead, Onyx_Agate, Glass_Joker, Showman, Flower_Pot, Merry_Andy,
    Oops_All_6s, The_Idol, Seeing_Double, Matador, Satellite, Cartomancer, Astronomer, Bootstraps
};
__constant item DCS_LOCKED_RARES[] = {
    Blueprint, Wee_Joker, Hit_the_Road, The_Duo, The_Trio, The_Family, The_Order, The_Tribe,
    Stuntman, Invisible_Joker, Brainstorm, Drivers_License, Burnt_Joker
};
__constant item DCS_UNLOCKED_UNCOMMONS[] = {Showman};
__constant item DCS_UNLOCKED_RARES[] = {Blueprint, Brainstorm};
#define DCS_APPLY(list, fn) for (int _i = 0; _i < (int)(sizeof(list) / sizeof(item)); _i++) fn(inst, list[_i]);

__constant item DCS_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item DCS_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

int dcs_frames(int ante) {
    if (ante <= 3) return 30;
    if (ante <= 10) return 80 + 3 * (ante - 4);
    if (ante <= 15) return 100 + 4 * (ante - 11);
    return 116 + 5 * (ante - 15);
}

// A draw off a node's own state, held in a register for the whole ante, split
// into its two halves. Advancing the state is arithmetic; randomseed is the
// expensive part. An edition poll is only ever READ for a Rare, so ~95% of them
// need the advance and nothing else -- but the node still has to move, because
// it is consumed once per joker whatever the rarity.
inline double dcs_step(instance* inst, double* state) {
    *state = roundDigits(fract(*state * 1.72431234 + 2.134453429141), 13);
    return (*state + inst->hashedSeed) / 2;
}
inline double dcs_value(double stepped, lrandom* scratch) {
    *scratch = randomseed(stepped);
    return l_random(scratch);
}

long filter(instance* inst) {
    for (int i = 0; i < (int)(sizeof(DCS_UPGRADE_VOUCHERS) / sizeof(item)); i++)
        i_lock(inst, DCS_UPGRADE_VOUCHERS[i]);
    DCS_APPLY(DCS_LOCKED_COMMONS, i_lock)
    DCS_APPLY(DCS_LOCKED_UNCOMMONS, i_lock)
    DCS_APPLY(DCS_LOCKED_RARES, i_lock)
    DCS_APPLY(DCS_UNLOCKED_UNCOMMONS, i_unlock)
    DCS_APPLY(DCS_UNLOCKED_RARES, i_unlock)

    shop sh = get_shop_instance(inst);
    double totalRate = get_total_rate(sh);
    bool overstock = false, overstockPlus = false;
    long negative = 0, base = 0;
    lrandom rng;

    for (int ante = 1; ante <= DCS_LAST_ANTE; ante++) {
        // Every node here is ante-keyed, so last ante's slots are unreachable.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;

        // Vouchers are drawn from ante 1: an early Overstock widens the frames.
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(DCS_BOUGHT_VOUCHERS) / sizeof(item)); i++)
            if (DCS_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante < DCS_FIRST_ANTE) continue;

        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
        int cards = dcs_frames(ante) * frameSize;

        // Card types first, densely, so the joker streams below are consumed
        // without an interleaved poll on another node.
        rng_node_id ctNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2);
        double ctState = inst->rngCache.nodes[ctNode].rngState;
        int jokers = 0;
        for (int i = 0; i < cards; i++)
            jokers += get_item_type(sh, dcs_value(dcs_step(inst, &ctState), &rng) * totalRate) == ItemType_Joker;
        inst->rngCache.nodes[ctNode].rngState = ctState;
        if (jokers == 0) continue;

        rng_node_id rarNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, ante, S_Shop}, 3);
        rng_node_id edNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Edition, S_Shop, ante}, 3);
        double rarState = inst->rngCache.nodes[rarNode].rngState;
        double edState = inst->rngCache.nodes[edNode].rngState;

        for (int j = 0; j < jokers; j++) {
            bool rare = dcs_value(dcs_step(inst, &rarState), &rng) > 0.95;
            // Advance the edition node for every joker -- it is consumed once
            // per joker -- but only pay for randomseed when the value is read.
            double edStepped = dcs_step(inst, &edState);
            if (!rare) continue;
            double ed = dcs_value(edStepped, &rng);
            // Identity is drawn only here. Writing the hoisted states back
            // first: randchoice_common goes through the cache and would
            // otherwise work from a stale copy of these two nodes.
            inst->rngCache.nodes[rarNode].rngState = rarState;
            inst->rngCache.nodes[edNode].rngState = edState;
            item joker = randchoice_common(inst, R_Joker_Rare, S_Shop, ante, RARE_JOKERS);
            if (joker == Blueprint || joker == Brainstorm) {
                if (ed > 0.997) negative++;        // Negative
                else if (ed <= 0.96) base++;       // no edition at all
            }
        }
        inst->rngCache.nodes[rarNode].rngState = rarState;
        inst->rngCache.nodes[edNode].rngState = edState;
        inst->rng = rng;
    }
    if (negative > 9999) negative = 9999;
    if (base > 9999) base = 9999;
    return negative * 10000 + base;
}
