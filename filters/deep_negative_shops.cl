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
// own nodes and cannot fire at White Stake. Every joker's rarity, identity and
// edition is drawn: Diet Cola is Uncommon, copy jokers are Rare, and the
// identity streams are shared across the ante, so none can be skipped.
// 1024 nodes overflowed on ~2% of pool seeds once the joker locks were added:
// every locked joker that comes up costs a resample node per rarity, ante and
// reroll depth. 2048 covers every seed seen in a 3000-seed sample with room.
#define CACHE_SIZE 2048
#include "lib/immolate.cl"

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
__constant item DNS_UNLOCKED_UNCOMMONS[] = {};
__constant item DNS_UNLOCKED_RARES[] = {};

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

// Classify one joker draw from `src`: rarity, identity where needed, edition.
inline void dns_joker(instance* inst, rsrc src, int ante, dns_counts* c, item* drawn) {
    rarity r = next_joker_rarity(inst, src, ante);
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

long filter(instance* inst) {
    for (int i = 0; i < (int)(sizeof(DNS_UPGRADE_VOUCHERS) / sizeof(item)); i++) i_lock(inst, DNS_UPGRADE_VOUCHERS[i]);
    DNS_APPLY_LOCKS(DNS_LOCKED_COMMONS, i_lock)
    DNS_APPLY_LOCKS(DNS_LOCKED_UNCOMMONS, i_lock)
    DNS_APPLY_LOCKS(DNS_LOCKED_RARES, i_lock)
    DNS_APPLY_LOCKS(DNS_UNLOCKED_COMMONS, i_unlock)
    DNS_APPLY_LOCKS(DNS_UNLOCKED_UNCOMMONS, i_unlock)
    DNS_APPLY_LOCKS(DNS_UNLOCKED_RARES, i_unlock)
    shop shopInstance = get_shop_instance(inst);
    double totalRate = get_total_rate(shopInstance);
    bool overstock = false, overstockPlus = false;
    dns_counts c = {0, 0, 0};
    int firstTagNeg = 0, secondTagNeg = 0;

    for (int ante = 1; ante <= DNS_LAST_ANTE; ante++) {
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
        for (int i = 0; i < cards; i++) {
            double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * totalRate;
            if (get_item_type(shopInstance, card_type) != ItemType_Joker) continue;
            item unused;
            dns_joker(inst, S_Shop, ante, &c, &unused);
        }
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
