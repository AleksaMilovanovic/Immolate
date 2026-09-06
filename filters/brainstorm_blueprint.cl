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
// this filter observes. Per seed that is ~14 card-type polls, ~10 rarity
// polls, 9 pack polls and a rare-identity draw for about one slot in twenty.
#include "lib/immolate.cl"

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
