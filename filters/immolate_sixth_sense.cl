// Sixth Sense obtainable, then Immolate from it, in antes 1-SS_MAX_ANTE (3).
//
// Sixth Sense must appear in a shop or Buffoon Pack of some ante A <=
// SS_MAX_ANTE. Then the first SS_TRIGGERS (2) spectral cards Sixth Sense would
// create in each of antes A..SS_MAX_ANTE are checked; score is the number that
// are Immolate, so `-c 1` prints any hit. A card created in the same ante A
// assumes Sixth Sense was bought before that ante's boss blind; define
// SS_NEXT_ANTE_ONLY to count only antes after A.
//
// Shop and pack slots per ante follow wr_filter (4 items + 3 packs in ante 1,
// 10 + 6 afterwards), no rerolls; the first ante-1 pack is the forced Buffoon.
//
// Cost-cutting, all exact:
//  * The Sixth Sense creations are checked first: one RNG node per ante, two
//    draws each, and ~68% of seeds have no Immolate at all and stop there.
//  * Sixth Sense is Uncommon, so a joker's identity is drawn only when its
//    rarity poll says Uncommon; Common/Rare identities, editions, stickers and
//    non-joker shop cards live on nodes nothing here reads, and the temporary
//    in-pack locks they would set only affect their own rarity pool.
//  * The shop scan stops at the first Sixth Sense, and never runs past the
//    last ante with an Immolate.
#include "lib/immolate.cl"

#ifndef SS_TRIGGERS
#define SS_TRIGGERS 2
#endif
#ifndef SS_MAX_ANTE
#define SS_MAX_ANTE 3
#endif
#ifndef SS_SHOP_ANTE1
#define SS_SHOP_ANTE1 4
#endif
#ifndef SS_SHOP_LATER
#define SS_SHOP_LATER 10
#endif
#ifndef SS_PACKS_ANTE1
#define SS_PACKS_ANTE1 3
#endif
#ifndef SS_PACKS_LATER
#define SS_PACKS_LATER 6
#endif

// Identity of an Uncommon joker at the next draw from `src`, or RETRY if the
// draw is not Uncommon. Mirrors next_joker for the Uncommon branch only.
inline item ss_uncommon_joker(instance* inst, rsrc src, int ante) {
    if (next_joker_rarity(inst, src, ante) != Rarity_Uncommon) return RETRY;
    return randchoice_common(inst, R_Joker_Uncommon, src, ante, UNCOMMON_JOKERS);
}

// True if Sixth Sense is in any shop slot or Buffoon Pack of `ante`.
bool ss_ante_has_sixth_sense(instance* inst, int ante, shop shopInstance, double totalRate) {
    bool found = false;
    int shopItems = ante == 1 ? SS_SHOP_ANTE1 : SS_SHOP_LATER;
    for (int i = 0; i < shopItems && !found; i++) {
        double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * totalRate;
        if (get_item_type(shopInstance, card_type) != ItemType_Joker) continue;
        if (ss_uncommon_joker(inst, S_Shop, ante) == Sixth_Sense) found = true;
    }
    int packs = ante == 1 ? SS_PACKS_ANTE1 : SS_PACKS_LATER;
    for (int p = 0; p < packs && !found; p++) {
        pack _pack = pack_info(next_pack(inst, ante));
        if (_pack.type != Buffoon_Pack) continue;
        item drawn[5];
        for (int j = 0; j < _pack.size; j++) {
            drawn[j] = ss_uncommon_joker(inst, S_Buffoon, ante);
            if (drawn[j] == Sixth_Sense) found = true;
            if (drawn[j] != RETRY && !inst->params.showman) i_lock(inst, drawn[j]);
        }
        for (int j = 0; j < _pack.size; j++) {
            if (drawn[j] != RETRY) i_unlock(inst, drawn[j]);
        }
    }
    return found;
}

long filter(instance* inst) {
    // Immolates among the first SS_TRIGGERS creations of each ante.
    int immolates[SS_MAX_ANTE + 1];
    int lastAnteWithImmolate = 0;
    for (int ante = 1; ante <= SS_MAX_ANTE; ante++) {
        int n = 0;
        for (int t = 0; t < SS_TRIGGERS; t++) {
            if (next_spectral(inst, S_Sixth_Sense, ante, false) == Immolate) n++;
        }
        immolates[ante] = n;
        if (n > 0) lastAnteWithImmolate = ante;
    }
    if (lastAnteWithImmolate == 0) return 0;

    // Earliest ante offering Sixth Sense, no later than the last useful one.
    shop shopInstance = get_shop_instance(inst);
    double totalRate = get_total_rate(shopInstance);
#ifdef SS_NEXT_ANTE_ONLY
    int lastUsefulAnte = lastAnteWithImmolate - 1;
#else
    int lastUsefulAnte = lastAnteWithImmolate;
#endif
    for (int ante = 1; ante <= lastUsefulAnte; ante++) {
        if (!ss_ante_has_sixth_sense(inst, ante, shopInstance, totalRate)) continue;
        long score = 0;
#ifdef SS_NEXT_ANTE_ONLY
        for (int a = ante + 1; a <= SS_MAX_ANTE; a++) score += immolates[a];
#else
        for (int a = ante; a <= SS_MAX_ANTE; a++) score += immolates[a];
#endif
        return score;
    }
    return 0;
}
