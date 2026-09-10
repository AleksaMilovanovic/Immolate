// Brainstorm and Blueprint both obtainable in antes 1-2 (shops and Buffoon
// Packs). Score is the number of the two found (0, 1 or 2), so `-c 2` prints
// seeds with both and `-c 1` seeds with either.
//
// Shop and pack sizes match wr_filter: BB_SHOP_ANTE1 / BB_PACKS_ANTE1 slots in
// ante 1 and BB_SHOP_ANTE2 / BB_PACKS_ANTE2 in ante 2, no rerolls. The first
// pack of ante 1 is the game's forced Buffoon Pack and is scanned like any other.
//
// Cost-cutting, all exact: both targets are Rare, so a joker's identity is only
// drawn when its rarity poll says Rare. Common/Uncommon identities, editions,
// stickers and the tarot/planet for non-joker shop slots all live on RNG nodes
// nothing here reads, and the temporary in-pack locks they would set can only
// affect draws from their own rarity pool, so skipping them changes no value
// this filter observes. Locked Common/Uncommon jokers likewise only reroll
// within their own pool, which is never drawn here. Per seed that is ~14 card-type polls, ~10 rarity
// polls, 9 pack polls and a rare-identity draw for about one slot in twenty.
#include "lib/immolate.cl"

// ---------------------------------------------------------------------------
// Joker locks. A locked joker cannot appear: when the game rolls one it
// rerolls within the same rarity, which shifts every later draw from that
// rarity pool. The LOCKED lists are the jokers a fresh Balatro profile has not
// yet unlocked (from init_locks in lib/instance.cl, split by rarity). Anything
// in an UNLOCKED list is removed from the locks again. Brainstorm and
// Blueprint are both fresh-profile locks, so BB_UNLOCKED_RARES defaults to
// the two of them: with either locked the filter could never score. Add more
// jokers there as your profile earns them. An empty list is {}.
// Only Rare identities are drawn here, so the common and uncommon lists have
// no effect on the result; they are kept so the three deep/shop filters share
// one layout and can be edited the same way.
// ---------------------------------------------------------------------------
__constant item BB_LOCKED_COMMONS[] = {
    Golden_Ticket, Swashbuckler, Hanging_Chad, Shoot_the_Moon
};
__constant item BB_LOCKED_UNCOMMONS[] = {
    Mr_Bones, Acrobat, Sock_and_Buskin, Troubadour, Certificate, Smeared_Joker, Throwback,
    Rough_Gem, Bloodstone, Arrowhead, Onyx_Agate, Glass_Joker, Showman, Flower_Pot, Merry_Andy,
    Oops_All_6s, The_Idol, Seeing_Double, Matador, Satellite, Cartomancer, Astronomer, Bootstraps
};
__constant item BB_LOCKED_RARES[] = {
    Blueprint, Wee_Joker, Hit_the_Road, The_Duo, The_Trio, The_Family, The_Order, The_Tribe,
    Stuntman, Invisible_Joker, Brainstorm, Drivers_License, Burnt_Joker
};
__constant item BB_UNLOCKED_COMMONS[] = {};
__constant item BB_UNLOCKED_UNCOMMONS[] = {};
__constant item BB_UNLOCKED_RARES[] = { Brainstorm, Blueprint };

#define BB_APPLY_LOCKS(list, fn) for (int _i = 0; _i < (int)(sizeof(list) / sizeof(item)); _i++) fn(inst, list[_i]);

#ifndef BB_SHOP_ANTE1
#define BB_SHOP_ANTE1 4
#endif
#ifndef BB_SHOP_ANTE2
#define BB_SHOP_ANTE2 10
#endif
#ifndef BB_PACKS_ANTE1
#define BB_PACKS_ANTE1 3
#endif
#ifndef BB_PACKS_ANTE2
#define BB_PACKS_ANTE2 6
#endif

// Identity of a Rare joker at the next draw from `src`, or RETRY if the draw is
// not Rare. Mirrors next_joker for the Rare branch only.
inline item bb_rare_joker(instance* inst, rsrc src, int ante) {
    if (next_joker_rarity(inst, src, ante) != Rarity_Rare) return RETRY;
    return randchoice_common(inst, R_Joker_Rare, src, ante, RARE_JOKERS);
}

long filter(instance* inst) {
    BB_APPLY_LOCKS(BB_LOCKED_COMMONS, i_lock)
    BB_APPLY_LOCKS(BB_LOCKED_UNCOMMONS, i_lock)
    BB_APPLY_LOCKS(BB_LOCKED_RARES, i_lock)
    BB_APPLY_LOCKS(BB_UNLOCKED_COMMONS, i_unlock)
    BB_APPLY_LOCKS(BB_UNLOCKED_UNCOMMONS, i_unlock)
    BB_APPLY_LOCKS(BB_UNLOCKED_RARES, i_unlock)
    bool brainstorm = false, blueprint = false;
    shop shopInstance = get_shop_instance(inst);
    double totalRate = get_total_rate(shopInstance);
    for (int ante = 1; ante <= 2; ante++) {
        int shopItems = ante == 1 ? BB_SHOP_ANTE1 : BB_SHOP_ANTE2;
        for (int i = 0; i < shopItems; i++) {
            double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * totalRate;
            if (get_item_type(shopInstance, card_type) != ItemType_Joker) continue;
            item joker = bb_rare_joker(inst, S_Shop, ante);
            if (joker == Brainstorm) brainstorm = true;
            if (joker == Blueprint) blueprint = true;
        }
        int packs = ante == 1 ? BB_PACKS_ANTE1 : BB_PACKS_ANTE2;
        for (int p = 0; p < packs; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            if (_pack.type != Buffoon_Pack) continue;
            // buffoon_pack without the non-Rare identity draws: Rare jokers are
            // locked while the pack is open, exactly as buffoon_pack does.
            item drawn[5];
            for (int j = 0; j < _pack.size; j++) {
                drawn[j] = bb_rare_joker(inst, S_Buffoon, ante);
                if (drawn[j] == Brainstorm) brainstorm = true;
                if (drawn[j] == Blueprint) blueprint = true;
                if (drawn[j] != RETRY && !inst->params.showman) i_lock(inst, drawn[j]);
            }
            for (int j = 0; j < _pack.size; j++) {
                if (drawn[j] != RETRY) i_unlock(inst, drawn[j]);
            }
        }
        if (brainstorm && blueprint) return 2;
    }
    return (long)brainstorm + (long)blueprint;
}
