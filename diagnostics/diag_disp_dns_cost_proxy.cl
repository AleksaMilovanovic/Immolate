// DIAGNOSTIC ONLY - not a real filter, never wired into correctness goldens.
//
// Cheap predictor of deep_negative_shops' per-seed cost. DNS's cost is
// dominated by the number of shop cards it draws, which is
//     sum over antes 3..38 of dns_frames(ante) * frameSize(ante)
// and frameSize depends only on when Overstock and Overstock Plus first appear
// as the ante voucher. So replaying only the voucher stream (38 draws instead
// of ~63,000) predicts the card count exactly.
//
// Returns the predicted shop-card count. Used to bucket a seed pool by cost so
// a dispatch experiment can compare a cost-homogeneous pool against a mixed one
// and measure the warp-divergence tax directly.
#define CACHE_SIZE 64
#include "lib/immolate.cl"

__constant item DIAG_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item DIAG_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

int diag_frames(int ante) {
    if (ante <= 3) return 30;
    if (ante <= 10) return 80 + 3 * (ante - 4);
    if (ante <= 15) return 100 + 4 * (ante - 11);
    return 116 + 5 * (ante - 15);
}

long filter(instance* inst) {
    for (int i = 0; i < (int)(sizeof(DIAG_UPGRADE_VOUCHERS) / sizeof(item)); i++) i_lock(inst, DIAG_UPGRADE_VOUCHERS[i]);
    bool overstock = false, overstockPlus = false;
    long cards = 0;
    for (int ante = 1; ante <= 38; ante++) {
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(DIAG_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
            if (DIAG_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante < 3) continue;
        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
        cards += (long)diag_frames(ante) * frameSize;
    }
    return cards;
}
