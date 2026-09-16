// Negative Rare jokers in the shops of antes 3-10, weighted towards early ones.
//
//   score = sum over each negative Rare of (ENR_WEIGHT_BASE - ante)
//
// so one in ante 3 is worth 17 and one in ante 10 is worth 10. A seed with no
// negative Rare at all scores 0.
//
// Same shop queue as deep_negative_shops and analyze_naneinf_negatives -- same
// frame counts, same frame sizes, same voucher handling -- so the card totals
// line up with theirs. See the deep_negative_shops header for that reasoning.
//
// WHAT IT DOES NOT DO, which is most of why it is quick:
//   - No joker identities are ever drawn. The filter only asks "is this Rare",
//     never "which Rare", so the identity streams are untouched.
//   - Nothing is locked, so nothing ever resamples. The only locks are the
//     voucher upgrades, and those exist solely to reproduce the deep filters'
//     frame sizes -- a voucher pool that resamples differently would change how
//     many cards an ante has.
//
// Edition is tested before rarity, which is the point of the whole loop. Both
// polls are consumed once per joker card whatever happens, but ADVANCING a
// node's state is arithmetic while reading a value from it costs a randomseed.
// Only 0.3% of jokers are Negative, so the rarity value is computed for those
// and skipped for the rest -- the state still moves, so the stream is exact.
#ifndef CACHE_SIZE
#define CACHE_SIZE 32
#endif
// No deck path here, so drop the 52-item starting deck from every work-item's
// instance: the instance lives in local memory on a GPU, and its size is
// occupancy.
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef ENR_FIRST_ANTE
#define ENR_FIRST_ANTE 3
#endif
#ifndef ENR_LAST_ANTE
#define ENR_LAST_ANTE 10
#endif
// -D ENR_COUNT_ONLY returns the plain count instead of the weighted total,
// which is what makes the weighting checkable against another filter.
// A negative Rare in ante A is worth (ENR_WEIGHT_BASE - A).
#ifndef ENR_WEIGHT_BASE
#define ENR_WEIGHT_BASE 20
#endif

// Vouchers whose first sighting counts as bought, and the upgrades that start
// locked. Same lists as the deep filters; only Overstock and Overstock Plus
// change anything here, but the rest have to be activated too or the voucher
// pool -- and with it the frame size -- drifts from theirs.
__constant item ENR_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item ENR_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

int enr_frames(int ante) {
    if (ante <= 3) return 30;
    if (ante <= 10) return 80 + 3 * (ante - 4);
    if (ante <= 15) return 100 + 4 * (ante - 11);
    return 116 + 5 * (ante - 15);
}

// A draw off a node's own state, held in a register for the whole ante, split
// into its two halves: advancing is arithmetic, randomseed is the expensive
// part. A node consumed once per card must always be advanced; its value is
// only worth paying for when something actually reads it.
inline double enr_step(instance* inst, double* state) {
    *state = roundDigits(fract(*state * 1.72431234 + 2.134453429141), 13);
    return (*state + inst->hashedSeed) / 2;
}
inline double enr_value(double stepped, lrandom* scratch) {
    *scratch = randomseed(stepped);
    return l_random(scratch);
}

long filter(instance* inst) {
    for (int i = 0; i < (int)(sizeof(ENR_UPGRADE_VOUCHERS) / sizeof(item)); i++)
        i_lock(inst, ENR_UPGRADE_VOUCHERS[i]);

    shop sh = get_shop_instance(inst);
    // Joker is the FIRST band get_item_type tests, so "is this a joker" is just
    // poll * totalRate < jokerRate, i.e. poll < jokerRate/totalRate. Folding the
    // scale into a threshold computed once removes a multiply and a band walk
    // from every one of the ~1300 cards a seed looks at.
    double jokerThreshold = sh.jokerRate / get_total_rate(sh);
    bool overstock = false, overstockPlus = false;
    long score = 0;
    lrandom rng;

    for (int ante = 1; ante <= ENR_LAST_ANTE; ante++) {
        // Every node reachable here is ante-keyed, so the previous ante's slots
        // are unreachable; discarding them keeps rng_node_resolve's linear scan
        // to the few nodes that are live.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;

        // Vouchers are drawn from ante 1: an early Overstock widens every later
        // frame, so the antes before ENR_FIRST_ANTE still have to be walked.
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(ENR_BOUGHT_VOUCHERS) / sizeof(item)); i++)
            if (ENR_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante < ENR_FIRST_ANTE) continue;

        // The ante-based widening cannot fire below ante 12, but it is kept so
        // raising ENR_LAST_ANTE stays consistent with the deep filters.
        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
        int cards = enr_frames(ante) * frameSize;

        // Card types first, densely, so the two joker streams below are
        // consumed without an interleaved poll on another node.
        rng_node_id ctNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2);
        double ctState = inst->rngCache.nodes[ctNode].rngState;
        int jokers = 0;
        for (int i = 0; i < cards; i++)
            jokers += enr_value(enr_step(inst, &ctState), &rng) < jokerThreshold;
        inst->rngCache.nodes[ctNode].rngState = ctState;
        if (jokers == 0) continue;

        rng_node_id rarNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, ante, S_Shop}, 3);
        rng_node_id edNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Edition, S_Shop, ante}, 3);
        double rarState = inst->rngCache.nodes[rarNode].rngState;
        double edState = inst->rngCache.nodes[edNode].rngState;
        int weight = ENR_WEIGHT_BASE - ante;

        for (int j = 0; j < jokers; j++) {
            // Both nodes move for every joker; only the edition's value is read
            // every time. Rarity and edition live on separate nodes, so testing
            // them in this order is exact -- each is still consumed in card
            // order, which is all that matters.
            double ed = enr_value(enr_step(inst, &edState), &rng);
            double rarStepped = enr_step(inst, &rarState);
            if (ed <= 0.997) continue;                                  // not Negative
#ifdef ENR_COUNT_ONLY
            if (enr_value(rarStepped, &rng) > 0.95) score += 1;         // diagnostic
#else
            if (enr_value(rarStepped, &rng) > 0.95) score += weight;    // Rare
#endif
        }
        inst->rngCache.nodes[rarNode].rngState = rarState;
        inst->rngCache.nodes[edNode].rngState = edState;
        inst->rng = rng;
    }
    return score;
}
