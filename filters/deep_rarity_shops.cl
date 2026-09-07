// Deep shop scan, antes 3-38: jokers counted by rarity. Same shops, packs and
// voucher rules as deep_negative_shops; only what is counted differs.
// Meant to run over a seed-supplier pool (--from); at ~11,000 shop cards per
// seed it is far too slow for a raw walk.
//
// Shops. Each ante has a number of shop "frames" (reroll windows):
//   ante 3: 30;  antes 4-10: 80 + 3 per ante;  antes 11-15: 100 + 4 per ante;
//   ante 16 on: +5 per ante (121 at ante 16, 231 at ante 38).
// A frame is 2 cards, 3 from the ante Overstock is first seen or from ante 12,
// and 4 from the ante Overstock Plus is first seen or from ante 24. Cards per
// ante is frames * frame size. Also the ante's DRS_PACKS packs, Buffoon only.
//
// Vouchers. The ante voucher is generated for every ante from 1 (an early
// Overstock enlarges the ante-3 shop). The first sighting of Overstock,
// Clearance Sale, Reroll Surplus, Telescope, Grabber, Wasteful, Seed Money,
// Blank, Director's Cut, Paint Brush or Hieroglyph, or of any of their
// upgrades, counts as bought: it leaves the pool and unlocks its upgrade, as in
// the game. Upgrades start locked. None of these change shop card-type rates.
//
// Score, three fields high to low:  rare (4 digits) | uncommon (4) | common (5)
// e.g. 612 rares, 3045 uncommons and 9130 commons prints as 612304509130
// (leading zeros of the rare field are not printed). Pool seeds measured
// ~560-830 rares, ~3000-3900 uncommons and ~8800-11000 commons, so the widths
// leave headroom; each field saturates rather than carrying into its
// neighbour. The score is a 64-bit long throughout Immolate (filter return,
// kernel cutoff compare), so 13 digits is fine.
//
// Draws skipped, all exact: consumable identities for non-joker slots; the
// sticker and rental polls, which cannot fire at White Stake; and every joker
// identity and edition. Only the rarity poll is read, and rarity lives on its
// own node (rarity + ante + source) that no identity or edition draw touches.
// Legendary never comes from a shop or Buffoon Pack, so it is not counted.
// Buffoon Pack cards are counted the same way; the in-pack reroll locks only
// matter for identities, which are not drawn.
#define CACHE_SIZE 512
#include "lib/immolate.cl"

#ifndef DRS_FIRST_ANTE
#define DRS_FIRST_ANTE 3
#endif
#ifndef DRS_LAST_ANTE
#define DRS_LAST_ANTE 38
#endif
#ifndef DRS_PACKS
#define DRS_PACKS 6
#endif

__constant item DRS_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item DRS_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

int drs_frames(int ante) {
    if (ante <= 3) return 30;
    if (ante <= 10) return 80 + 3 * (ante - 4);
    if (ante <= 15) return 100 + 4 * (ante - 11);
    return 116 + 5 * (ante - 15);
}

inline void drs_count(rarity r, int* rare, int* uncommon, int* common) {
    if (r == Rarity_Rare) (*rare)++;
    else if (r == Rarity_Uncommon) (*uncommon)++;
    else if (r == Rarity_Common) (*common)++;
}

long filter(instance* inst) {
    for (int i = 0; i < (int)(sizeof(DRS_UPGRADE_VOUCHERS) / sizeof(item)); i++) i_lock(inst, DRS_UPGRADE_VOUCHERS[i]);
    shop shopInstance = get_shop_instance(inst);
    double totalRate = get_total_rate(shopInstance);
    bool overstock = false, overstockPlus = false;
    int rare = 0, uncommon = 0, common = 0;

    for (int ante = 1; ante <= DRS_LAST_ANTE; ante++) {
        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(DRS_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
            if (DRS_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;
        if (ante < DRS_FIRST_ANTE) continue;

        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
        int cards = drs_frames(ante) * frameSize;
        for (int i = 0; i < cards; i++) {
            double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * totalRate;
            if (get_item_type(shopInstance, card_type) != ItemType_Joker) continue;
            drs_count(next_joker_rarity(inst, S_Shop, ante), &rare, &uncommon, &common);
        }
        for (int p = 0; p < DRS_PACKS; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            if (_pack.type != Buffoon_Pack) continue;
            for (int j = 0; j < _pack.size; j++) {
                drs_count(next_joker_rarity(inst, S_Buffoon, ante), &rare, &uncommon, &common);
            }
        }
    }
    if (rare > 9999) rare = 9999;
    if (uncommon > 9999) uncommon = 9999;
    if (common > 99999) common = 99999;
    return (long)rare * 1000000000L + (long)uncommon * 100000L + (long)common;
}
