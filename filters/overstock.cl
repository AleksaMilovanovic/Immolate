// With the per-ante reset below only one ante's nodes are live: one voucher
// draw plus its resample chain. The node array is the bulk of `instance`, which
// is local memory on a GPU, so its size is occupancy.
#ifndef CACHE_SIZE
#define CACHE_SIZE 32
#endif
// No deck path here, so drop the 52-item starting deck from the instance.
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef OS_MAX_ANTE
#define OS_MAX_ANTE 38
#endif
// Overstock must appear by OS_OVERSTOCK_BY and Overstock Plus by
// OS_PLUS_BY, both inclusive: the test runs after that ante's voucher is
// drawn, so an ante-7 Overstock passes OS_OVERSTOCK_BY 7.
//
// Note this is one ante stricter than the old hard-coded form. That read
// `ante > 15 && !overstock`, which fires only after ante 16's draw -- so it
// actually allowed Overstock to arrive in ante 16, not 15. The `>=` below means
// the number says what it does.
#ifndef OS_OVERSTOCK_BY
#define OS_OVERSTOCK_BY 7
#endif
#ifndef OS_PLUS_BY
#define OS_PLUS_BY 13
#endif

__constant item OS_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item OS_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

long filter(instance* inst) {
    init_locks(inst, 1, false, false);
    for (int i = 0; i < (int)(sizeof(OS_UPGRADE_VOUCHERS) / sizeof(item)); i++) i_lock(inst, OS_UPGRADE_VOUCHERS[i]);
    bool overstock = false, overstockPlus = false;
    for (int ante = 1; ante <= OS_MAX_ANTE; ante++) {
        // Voucher nodes are ante-keyed -- (R_Voucher, ante) and its resample
        // chain -- so nothing from an earlier ante is read again. Discarding the
        // slots keeps rng_node_resolve's linear scan to the live handful instead
        // of every node the run has made. What DOES carry across antes is the
        // lock set that activate_voucher changes, and that lives in locked[],
        // not the cache. Same change as in negative_tags.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(OS_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
            if (OS_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        // Decided either way as soon as it can be: both found is a pass with no
        // reason to read further antes, and a missed deadline is a fail. The
        // old form ran all 38 antes whatever happened.
        if (overstock && overstockPlus) return 1;
        if (ante >= OS_OVERSTOCK_BY && !overstock) return 0;
        if (ante >= OS_PLUS_BY && !overstockPlus) return 0;
    }
    // Ran out of antes with one still missing.
    return 0;
}
