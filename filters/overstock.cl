#define CACHE_SIZE 512
#include "lib/immolate.cl"

#ifndef OS_MAX_ANTE
#define OS_MAX_ANTE 38
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
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(OS_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
            if (OS_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante > 15 && !overstock) {
            return 0;
        }
        if (ante > 25 && !overstockPlus) {
            return 0;
        }
    }
    // Simple pass/fail filter
    return 1;
}
