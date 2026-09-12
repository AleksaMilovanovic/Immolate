// Immolate from Sixth Sense or Seance in antes 1-SS_MAX_ANTE (3).
//
// Sixth Sense creates a spectral when a hand of a single 6 is played; Seance
// creates one when a Straight Flush is played. For each joker that appears in
// a shop or Buffoon Pack of some ante A <= SS_MAX_ANTE, the first few spectral
// cards it would create in each of antes A..SS_MAX_ANTE are checked:
// SS_TRIGGERS (2) per ante for Sixth Sense, SS_SEANCE_TRIGGERS (4) for Seance.
// Score is the number of those cards that are Immolate, summed over both
// jokers, so `-c 1` prints any hit. A card created in the same ante A assumes
// the joker was bought before that ante's boss blind; define SS_NEXT_ANTE_ONLY
// to count only antes after A. Set SS_SEANCE_TRIGGERS to 0 to ignore Seance.
//
// Shop and pack slots per ante follow wr_filter (4 items + 3 packs in ante 1,
// 10 + 6 afterwards), no rerolls; the first ante-1 pack is the forced Buffoon.
//
// Cost-cutting, all exact:
//  * The creations are checked first: one RNG node per joker per ante, a few
//    draws each, and most seeds have no Immolate anywhere and stop there.
//  * Both jokers are Uncommon, so a joker's identity is drawn only when its
//    rarity poll says Uncommon; Common/Rare identities, editions, stickers and
//    non-joker shop cards live on nodes nothing here reads, and the temporary
//    in-pack locks they would set (and the locked Common/Rare jokers below)
//    only affect their own rarity pool.
//  * One shop scan finds both jokers; it stops once both are found or once it
//    passes the last ante that has an Immolate for a joker not yet found.
//  * Joker locks: see the LOCKED / UNLOCKED lists below the include.
#include "lib/immolate.cl"

// ---------------------------------------------------------------------------
// Joker locks. A locked joker cannot appear: when the game rolls one it
// rerolls within the same rarity, which shifts every later draw from that
// rarity pool. The LOCKED lists are the jokers a fresh Balatro profile has not
// yet unlocked (from init_locks in lib/instance.cl, split by rarity). Anything
// in an UNLOCKED list is removed from the locks again; add jokers there as
// your profile earns them. Sixth Sense itself is available on a fresh profile,
// so the UNLOCKED lists start empty. An empty list is {}.
// Only Uncommon identities are drawn here, so the common and rare lists have
// no effect on the result; they are kept so the shop filters share one layout.
// ---------------------------------------------------------------------------
__constant item SS_LOCKED_COMMONS[] = {
    Golden_Ticket, Swashbuckler, Hanging_Chad, Shoot_the_Moon
};
__constant item SS_LOCKED_UNCOMMONS[] = {
    Mr_Bones, Acrobat, Sock_and_Buskin, Troubadour, Certificate, Smeared_Joker, Throwback,
    Rough_Gem, Bloodstone, Arrowhead, Onyx_Agate, Glass_Joker, Showman, Flower_Pot, Merry_Andy,
    Oops_All_6s, The_Idol, Seeing_Double, Matador, Satellite, Cartomancer, Astronomer, Bootstraps
};
__constant item SS_LOCKED_RARES[] = {
    Blueprint, Wee_Joker, Hit_the_Road, The_Duo, The_Trio, The_Family, The_Order, The_Tribe,
    Stuntman, Invisible_Joker, Brainstorm, Drivers_License, Burnt_Joker
};
__constant item SS_UNLOCKED_COMMONS[] = {};
__constant item SS_UNLOCKED_UNCOMMONS[] = {};
__constant item SS_UNLOCKED_RARES[] = {};

#define SS_APPLY_LOCKS(list, fn) for (int _i = 0; _i < (int)(sizeof(list) / sizeof(item)); _i++) fn(inst, list[_i]);

#ifndef SS_TRIGGERS
#define SS_TRIGGERS 2
#endif
#ifndef SS_SEANCE_TRIGGERS
#define SS_SEANCE_TRIGGERS 4
#endif
#ifndef SS_MAX_ANTE
#define SS_MAX_ANTE 4
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

// Scans the shop slots and Buffoon Packs of `ante`, setting *sixth / *seance
// to `ante` for each of the two jokers seen there for the first time. Stops
// early once both are known. Returns nothing; the callers read the two ints.
void ss_scan_ante(instance* inst, int ante, shop shopInstance, double totalRate, int* sixth, int* seance) {
    int shopItems = ante == 1 ? SS_SHOP_ANTE1 : SS_SHOP_LATER;
    for (int i = 0; i < shopItems && !(*sixth && *seance); i++) {
        double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * totalRate;
        if (get_item_type(shopInstance, card_type) != ItemType_Joker) continue;
        item j = ss_uncommon_joker(inst, S_Shop, ante);
        if (j == Sixth_Sense && !*sixth) *sixth = ante;
        if (j == Seance && !*seance) *seance = ante;
    }
    int packs = ante == 1 ? SS_PACKS_ANTE1 : SS_PACKS_LATER;
    for (int p = 0; p < packs && !(*sixth && *seance); p++) {
        pack _pack = pack_info(next_pack(inst, ante));
        if (_pack.type != Buffoon_Pack) continue;
        item drawn[5];
        for (int j = 0; j < _pack.size; j++) {
            drawn[j] = ss_uncommon_joker(inst, S_Buffoon, ante);
            if (drawn[j] == Sixth_Sense && !*sixth) *sixth = ante;
            if (drawn[j] == Seance && !*seance) *seance = ante;
            if (drawn[j] != RETRY && !inst->params.showman) i_lock(inst, drawn[j]);
        }
        for (int j = 0; j < _pack.size; j++) {
            if (drawn[j] != RETRY) i_unlock(inst, drawn[j]);
        }
    }
}

long filter(instance* inst) {
    SS_APPLY_LOCKS(SS_LOCKED_COMMONS, i_lock)
    SS_APPLY_LOCKS(SS_LOCKED_UNCOMMONS, i_lock)
    SS_APPLY_LOCKS(SS_LOCKED_RARES, i_lock)
    SS_APPLY_LOCKS(SS_UNLOCKED_COMMONS, i_unlock)
    SS_APPLY_LOCKS(SS_UNLOCKED_UNCOMMONS, i_unlock)
    SS_APPLY_LOCKS(SS_UNLOCKED_RARES, i_unlock)
    // Immolates among each joker's first creations of each ante.
    int sixthImm[SS_MAX_ANTE + 1], seanceImm[SS_MAX_ANTE + 1];
    int lastSixth = 0, lastSeance = 0; // last ante with an Immolate, per joker
    for (int ante = 1; ante <= SS_MAX_ANTE; ante++) {
        int n = 0;
        for (int t = 0; t < SS_TRIGGERS; t++) {
            if (next_spectral(inst, S_Sixth_Sense, ante, false) == Immolate) n++;
        }
        sixthImm[ante] = n;
        if (n > 0) lastSixth = ante;
        n = 0;
        for (int t = 0; t < SS_SEANCE_TRIGGERS; t++) {
            if (next_spectral(inst, S_Seance, ante, false) == Immolate) n++;
        }
        seanceImm[ante] = n;
        if (n > 0) lastSeance = ante;
    }
    if (lastSixth == 0 && lastSeance == 0) return 0;

#ifdef SS_NEXT_ANTE_ONLY
    const int sameAnte = 0;
#else
    const int sameAnte = 1;
#endif
    // A joker is only worth finding up to the last ante that has an Immolate
    // for it (one earlier if same-ante creations do not count).
    int usefulSixth = lastSixth - (sameAnte ? 0 : 1);
    int usefulSeance = lastSeance - (sameAnte ? 0 : 1);
    int lastUseful = usefulSixth > usefulSeance ? usefulSixth : usefulSeance;

    shop shopInstance = get_shop_instance(inst);
    double totalRate = get_total_rate(shopInstance);
    int sixthAnte = 0, seanceAnte = 0; // earliest ante each joker is offered
    for (int ante = 1; ante <= lastUseful; ante++) {
        // Stop looking for a joker once it is found or can no longer pay off.
        int wantSixth = !sixthAnte && ante <= usefulSixth;
        int wantSeance = !seanceAnte && ante <= usefulSeance;
        if (!wantSixth && !wantSeance) break;
        int sx = wantSixth ? 0 : -1, se = wantSeance ? 0 : -1; // -1: already settled, do not record
        ss_scan_ante(inst, ante, shopInstance, totalRate, &sx, &se);
        if (wantSixth && sx > 0) sixthAnte = sx;
        if (wantSeance && se > 0) seanceAnte = se;
    }

    long score = 0;
    if (sixthAnte) {
        for (int a = sixthAnte + (sameAnte ? 0 : 1); a <= SS_MAX_ANTE; a++) score += sixthImm[a];
    }
    if (seanceAnte) {
        for (int a = seanceAnte + (sameAnte ? 0 : 1); a <= SS_MAX_ANTE; a++) score += seanceImm[a];
    }
    return score;
}
