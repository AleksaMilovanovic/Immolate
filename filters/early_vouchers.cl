// 1 if both stage-1 vouchers are seen by ante EV_STAGE1_BY and both stage-2
// upgrades by EV_STAGE2_BY, else 0.
//
//   stage 1: Overstock, Blank
//   stage 2: Overstock Plus, Antimatter
//
// The stages are not independent: an upgrade starts locked and only enters the
// pool once its base voucher has been bought, so Overstock Plus cannot appear
// before Overstock nor Antimatter before Blank. A stage-2 deadline is therefore
// a deadline on the whole chain, not just on one draw.
//
// Vouchers on the BOUGHT list count as bought the first time they are seen,
// which is what unlocks the upgrades -- exactly as deep_negative_shops treats
// them, so the voucher stream matches the deep filters'.
//
// Deadlines are inclusive: the test runs after that ante's voucher is drawn, so
// an ante-8 Blank passes EV_STAGE1_BY 8.
#ifndef CACHE_SIZE
#define CACHE_SIZE 32
#endif
// No deck path, so drop the 52-item starting deck: the instance is local memory
// on a GPU and its size is occupancy.
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef EV_MAX_ANTE
#define EV_MAX_ANTE 38
#endif
#ifndef EV_STAGE1_BY
#define EV_STAGE1_BY 8
#endif
#ifndef EV_STAGE2_BY
#define EV_STAGE2_BY 12
#endif

__constant item EV_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item EV_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

long filter(instance* inst) {
    init_locks(inst, 1, false, false);
    for (int i = 0; i < (int)(sizeof(EV_UPGRADE_VOUCHERS) / sizeof(item)); i++)
        i_lock(inst, EV_UPGRADE_VOUCHERS[i]);

    bool overstock = false, blank = false;
    bool overstockPlus = false, antimatter = false;

    for (int ante = 1; ante <= EV_MAX_ANTE; ante++) {
        // Voucher nodes are ante-keyed, so an earlier ante's slots are never
        // read again; discarding them keeps rng_node_resolve's linear scan
        // short. What does carry over is the lock set activate_voucher changes,
        // and that lives in locked[], not the cache.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;

        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(EV_BOUGHT_VOUCHERS) / sizeof(item)); i++)
            if (EV_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }

        if (v == Overstock) overstock = true;
        else if (v == Blank) blank = true;
        else if (v == Overstock_Plus) overstockPlus = true;
        else if (v == Antimatter) antimatter = true;

        // Decided as early as it can be, either way.
        if (overstock && blank && overstockPlus && antimatter) return 1;
        if (ante >= EV_STAGE1_BY && !(overstock && blank)) return 0;
        if (ante >= EV_STAGE2_BY && !(overstockPlus && antimatter)) return 0;
    }
    return 0;   // ran out of antes with something still missing
}
