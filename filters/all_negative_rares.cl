// Every negative Rare joker one run could collect through ante ANR_LAST_ANTE.
// Score is the plain count, so `-c 3` prints seeds offering three or more.
//
// Counted as ONE feasible run, not as a menu of independent chances: a tag is
// spent on a single joker, and no card is ever counted by two routes.
//
// THE ROUTES
//
//  1. Natural. A shop card whose rarity poll says Rare and whose edition poll
//     says Negative. The shop is walked as reroll frames -- anr_frames(ante)
//     frames of 2 cards, 3 once Overstock is seen or from ante 12, 4 for
//     Overstock Plus or from ante 24 -- the same model and the same table as
//     early_negative_rares and deep_negative_shops.
//
//  2. Negative Tag. The tag turns the next BASE-EDITION joker to appear in the
//     shop Negative, so it pays off exactly when that joker is Rare. A
//     first-slot tag (small blind) lands in its own ante's shop; a second-slot
//     tag (big blind) lands in the NEXT ante's, the same +1 that analyzer.cl
//     applies to a big-blind tag's generated item. The tag sits pending while
//     the player rerolls, so the first base-edition joker of any frame is a
//     candidate, up to a fraction ANR_TAG_FRAME_DIV of the ante's frames.
//     One tag negatives one joker: when both a previous second-slot tag and
//     this ante's first-slot tag point at the same shop they need two
//     different frames, hence min(pending tags, frames offering a Rare).
//     Because a tag only ever targets a base-edition joker, a card already
//     counted by route 1 can never be counted here as well -- the two routes
//     are disjoint by construction, no dedupe pass needed.
//
//  3. Rare Tag. The tag's free Rare joker rolls its own edition off the tag's
//     own stream (edi + rta + ante): Balatro creates it with key_append 'rta',
//     which keys the edition poll too, which is why next_joker_with_info polls
//     next_joker_edition for every source rather than only for shop cards. So
//     a Rare Tag pays off when THAT roll is Negative; it needs nothing from
//     the shop and consumes nothing there. A second-slot Rare Tag reads the
//     next ante's key, again as analyzer.cl does.
//
//  4. Judgement. The ante's first ANR_JUDGEMENT_TRIGGERS Judgement jokers,
//     counted when the rarity poll says Rare and the edition poll Negative.
//     Ungated: owning a Judgement by then is assumed.
//
//  5. Wraith. Wraith always creates a Rare (next_joker_rarity hard-codes it,
//     no roll), so only the edition matters -- but a Wraith has to exist
//     first. Sixth Sense or Seance must have been offered in a shop or a
//     Buffoon Pack (the immolate_sixth_sense scan), and one of that joker's
//     first ANR_SPECTRAL_TRIGGERS creations in that ante or a later one must
//     be a Wraith. From the ante that happens the gate is satisfied for good:
//     the shop/pack scan and the trigger draws stop, and every ante from there
//     has its first ANR_WRAITH_TRIGGERS Wraith jokers checked.
//
//  6. Rare Tag and Negative Tag in the same ante. A shop appears after each
//     blind you BEAT, so skipping both blinds of an ante sends both of its
//     tags to one shop -- the one after that ante's boss, which is the next
//     ante's -- and there the Negative Tag lands on the Rare Tag's own free
//     Rare joker. That needs no edition roll and no shop frame, so the pair is
//     worth exactly 1 however the rest of the ante falls, and it spends both
//     tags: neither feeds route 2 or route 3. The Rare Tag's card is still
//     created in that next shop, so it still takes a draw from the next ante's
//     rta edition node (rtaOwed below) even though the tag overrides its value.
//
// WHAT IS NOT MODELLED
//  * Money. Every reroll inside the frame budget and every purchase is assumed
//    affordable, so the count is what the seed offers a well-funded run.
//  * The shops route 6 gives up. Taking it means skipping two blinds, so that
//    ante shows fewer shops than its frame budget assumes; the budget is not
//    reduced, the same way the frame model ignores skips everywhere else.
//  * Splitting a route 6 pair instead of taking it. Played apart the two tags
//    could in principle score 2 (a Negative Tag landing on some frame's Rare
//    AND the Rare Tag's own edition rolling Negative), but that needs a 0.3%
//    roll on top of a frame that offers a Rare, while the pair is a certainty,
//    so the pair is always taken. The count is a hit short in that rare case.
//  * The second-slot tag of ANR_LAST_ANTE, whose shop is past the horizon.
//
// -D ANR_DEBUG prints a per-ante, per-route breakdown (run it with -n 1 -g 1
// on one seed); the routes overlap enough that a bare total is hard to check.
//
// Draws skipped, all exact: joker identities are drawn only where an identity
// is read (the Uncommon pool, for finding Sixth Sense and Seance, and only
// over the slots a real shop shows). Rare, Common, Judgement and Wraith
// identities, sticker and rental polls, and consumable identities all live on
// their own nodes that nothing here reads, and nothing later reads them
// either, so not drawing them shifts no value this filter observes.

// Build options (pass with --build_opts "-D NAME" or "-D NAME=VALUE"):
// @opt CACHE_SIZE=256  rng node cache slots per work-item
// @opt ANR_LAST_ANTE=8  last ante whose shops, tags and creations are counted
// @opt ANR_TAG_FRAME_DIV=2  a pending Negative Tag may wait out 1/N of the ante's shop frames
// @opt ANR_JUDGEMENT_TRIGGERS=2  Judgement creations per ante checked for a negative Rare
// @opt ANR_WRAITH_TRIGGERS=3  Wraith creations per ante checked for Negative once Wraith is reachable
// @opt ANR_SPECTRAL_TRIGGERS=3  Sixth Sense / Seance spectral creations per ante checked for a Wraith
// @opt ANR_SHOP_ANTE1=4  ante-1 shop slots searched for Sixth Sense / Seance
// @opt ANR_SHOP_LATER=12  shop slots per later ante searched for Sixth Sense / Seance
// @opt ANR_PACKS_ANTE1=3  ante-1 packs searched for Sixth Sense / Seance
// @opt ANR_PACKS_LATER=6  packs per later ante searched for Sixth Sense / Seance
// @opt ANR_NEXT_ANTE_ONLY  a joker found in ante A only starts creating spectrals in ante A+1
// @opt ANR_DEBUG  print a per-ante, per-route breakdown (run on one seed with -n 1 -g 1)

#ifndef CACHE_SIZE
#define CACHE_SIZE 256
#endif
// No deck path here, so drop the 52-item starting deck from every work-item's
// instance: the instance lives in local memory on a GPU, and its size is
// occupancy.
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef ANR_LAST_ANTE
#define ANR_LAST_ANTE 8
#endif
// A pending Negative Tag may wait out this fraction of the ante's frames --
// 2 means half of them, the point past which rerolling for a better target
// stops being something a run would actually pay for.
#ifndef ANR_TAG_FRAME_DIV
#define ANR_TAG_FRAME_DIV 2
#endif
#ifndef ANR_JUDGEMENT_TRIGGERS
#define ANR_JUDGEMENT_TRIGGERS 2
#endif
#ifndef ANR_WRAITH_TRIGGERS
#define ANR_WRAITH_TRIGGERS 3
#endif
// Spectral creations per ante, per joker, checked for a Wraith.
#ifndef ANR_SPECTRAL_TRIGGERS
#define ANR_SPECTRAL_TRIGGERS 3
#endif
// Slots a real shop shows, i.e. how deep Sixth Sense / Seance are looked for.
// The frame budget above is a reroll model for cards nobody has to see; these
// are the ones actually on offer.
#ifndef ANR_SHOP_ANTE1
#define ANR_SHOP_ANTE1 4
#endif
#ifndef ANR_SHOP_LATER
#define ANR_SHOP_LATER 12
#endif
#ifndef ANR_PACKS_ANTE1
#define ANR_PACKS_ANTE1 3
#endif
#ifndef ANR_PACKS_LATER
#define ANR_PACKS_LATER 6
#endif
// By default a joker found in ante A may already trigger in ante A (bought
// before that ante's boss blind). Define ANR_NEXT_ANTE_ONLY to require A+1.
#ifdef ANR_NEXT_ANTE_ONLY
#define ANR_SAME_ANTE 0
#else
#define ANR_SAME_ANTE 1
#endif

// Vouchers whose first sighting counts as bought, and the upgrades that start
// locked. Same lists as the deep filters; only Overstock and Overstock Plus
// change anything here, but the rest have to be activated too or the voucher
// pool -- and with it the frame size -- drifts from theirs.
__constant item ANR_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item ANR_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};
// Tags a fresh-ish profile has not unlocked. A locked tag is rerolled within
// the tag pool, which shifts every later tag draw, so this list changes which
// antes offer Negative and Rare Tags. Same list and handling as negative_tags
// and deep_negative_shops -- edit them together. Empty ({}) for a completed
// profile. init_locks(ante 1) gates the ante-locked tags (Negative Tag among
// them) and init_unlocks lifts them on schedule; neither touches these three.
__constant item ANR_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };
// Uncommon jokers a fresh profile has not unlocked, from init_locks. Only the
// Uncommon pool is listed because Sixth Sense and Seance are Uncommon and no
// other identity is ever drawn here: a locked joker is rerolled within its own
// rarity pool, so the Common and Rare lists could not move anything this
// filter reads. Add jokers to ANR_UNLOCKED_UNCOMMONS as your profile earns
// them; Sixth Sense and Seance are both available on a fresh profile.
__constant item ANR_LOCKED_UNCOMMONS[] = {
    Mr_Bones, Acrobat, Sock_and_Buskin, Troubadour, Certificate, Smeared_Joker, Throwback,
    Rough_Gem, Bloodstone, Arrowhead, Onyx_Agate, Glass_Joker, Showman, Flower_Pot, Merry_Andy,
    Oops_All_6s, The_Idol, Seeing_Double, Matador, Satellite, Cartomancer, Astronomer, Bootstraps
};
__constant item ANR_UNLOCKED_UNCOMMONS[] = {};

#define ANR_APPLY_LOCKS(list, fn) for (int _i = 0; _i < (int)(sizeof(list) / sizeof(item)); _i++) fn(inst, list[_i]);

// Shop reroll frames per ante, the early_negative_rares table.
int anr_frames(int ante) {
    if (ante < 3) return 10;
    if (ante <= 7) return 20 + 2 * (ante - 4);
    if (ante <= 12) return 30 + 3 * (ante - 8);
    if (ante <= 15) return 50 + 4 * (ante - 13);
    return 116 + 5 * (ante - 15);
}

// Identity of an Uncommon joker at the next draw from `src`, or RETRY if the
// draw is not Uncommon. Mirrors next_joker for the Uncommon branch only.
inline item anr_uncommon_joker(instance* inst, rsrc src, int ante) {
    if (next_joker_rarity(inst, src, ante) != Rarity_Uncommon) return RETRY;
    return randchoice_common(inst, R_Joker_Uncommon, src, ante, UNCOMMON_JOKERS);
}

// True if any of the first ANR_SPECTRAL_TRIGGERS creations of `src` is a Wraith.
inline bool anr_wraith_in_triggers(instance* inst, rsrc src, int ante) {
    for (int t = 0; t < ANR_SPECTRAL_TRIGGERS; t++) {
        if (next_spectral(inst, src, ante, false) == Wraith) return true;
    }
    return false;
}

long filter(instance* inst) {
    for (int i = 0; i < (int)(sizeof(ANR_UPGRADE_VOUCHERS) / sizeof(item)); i++)
        i_lock(inst, ANR_UPGRADE_VOUCHERS[i]);
    ANR_APPLY_LOCKS(ANR_LOCKED_UNCOMMONS, i_lock)
    ANR_APPLY_LOCKS(ANR_UNLOCKED_UNCOMMONS, i_unlock)
    init_locks(inst, 1, false, false);
    ANR_APPLY_LOCKS(ANR_LOCKED_TAGS, i_lock)

    long count = 0;
    bool overstock = false, overstockPlus = false;
    item carriedTag = RETRY;  // previous ante's second-slot tag, due this ante
    int rtaOwed = 0;          // rta draws a previous ante's route 6 owes this one
    int sixthAnte = 0, seanceAnte = 0;  // ante each joker is first offered
    int wraithAnte = 0;                 // first ante a Wraith can be in hand

    for (int ante = 1; ante <= ANR_LAST_ANTE; ante++) {
        // Every node reachable here is ante-keyed (including the pack stream
        // in this game version), so the previous ante's slots are unreachable;
        // discarding them keeps rng_node_resolve's linear scan short.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        init_unlocks(inst, ante, false);

        item v = next_voucher(inst, ante);
        for (int i = 0; i < (int)(sizeof(ANR_BOUGHT_VOUCHERS) / sizeof(item)); i++)
            if (ANR_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
        if (v == Overstock) overstock = true;
        if (v == Overstock_Plus) overstockPlus = true;

        item tag1 = next_tag(inst, ante);
        item tag2 = next_tag(inst, ante);

        // Route 6. It spends both of the ante's tags, so they are withheld
        // from routes 2 and 3 below, and the Rare Tag's card is created in the
        // NEXT ante's shop, which owes that ante's rta node a draw.
        bool combo = (tag1 == Rare_Tag && tag2 == Negative_Tag)
                  || (tag1 == Negative_Tag && tag2 == Rare_Tag);
        count += combo ? 1 : 0;
        item slot1 = combo ? RETRY : tag1;
        item carryNext = combo ? RETRY : tag2;

        // Rare Tags, oldest first: a previous ante's big-blind tag, or the
        // card a previous ante's route 6 pushed into this shop, was earned
        // before this ante's small-blind tag, and all of them read this ante's
        // key, so they take that node's draws in that order. (A route 6 ante
        // carries nothing, so rtaOwed and carriedTag are never both set.)
        for (int i = 0; i < rtaOwed; i++) next_joker_edition(inst, S_Rare_Tag, ante);
        rtaOwed = combo ? 1 : 0;
        int rareTagHits = 0;
        if (carriedTag == Rare_Tag && next_joker_edition(inst, S_Rare_Tag, ante) == Negative) rareTagHits++;
        if (slot1 == Rare_Tag && next_joker_edition(inst, S_Rare_Tag, ante) == Negative) rareTagHits++;
        count += rareTagHits;

        int frameSize = 2;
        if (overstock || ante >= 12) frameSize = 3;
        if (overstockPlus || ante >= 24) frameSize = 4;
        int frames = anr_frames(ante);
        int cards = frames * frameSize;
        int tagFrames = frames / ANR_TAG_FRAME_DIV;
        int realShop = ante == 1 ? ANR_SHOP_ANTE1 : ANR_SHOP_LATER;
        // Sixth Sense and Seance are only worth looking for while neither the
        // Wraith gate is settled nor both jokers are already in hand.
        bool hunting = !wraithAnte && (!sixthAnte || !seanceAnte);

        int natural = 0;      // route 1 hits this ante
        int tagTargets = 0;   // frames whose first base-edition joker is Rare
        int curFrame = -1;
        bool frameTaken = false;
        for (int base = 0; base < cards; base += SHOP_MAX_ITEMS) {
            int m = cards - base < SHOP_MAX_ITEMS ? cards - base : SHOP_MAX_ITEMS;
            shopitem window[SHOP_MAX_ITEMS];
            // Uncommon identities only in the first window, and only while
            // hunting: the slots a real shop shows all sit there, and the
            // identity node is not read anywhere else.
            uint flags = SHOP_EDITIONS;
            if (hunting && base == 0) flags |= SHOP_IDENT_UNCOMMON;
            shop_items_dense(inst, ante, m, window, flags);
            for (int i = 0; i < m; i++) {
                if (window[i].type != ItemType_Joker) continue;
                int idx = base + i;
                int frame = idx / frameSize;
                if (frame != curFrame) { curFrame = frame; frameTaken = false; }
                item edition = window[i].joker.edition;
                rarity r = window[i].joker._rarity;
                // Route 1, anywhere in the frame budget.
                if (edition == Negative && r == Rarity_Rare) natural++;
                // Route 2's candidates: the first base-edition joker of a frame.
                if (frame < tagFrames && !frameTaken && edition == No_Edition) {
                    frameTaken = true;
                    if (r == Rarity_Rare) tagTargets++;
                }
                if (hunting && idx < realShop && r == Rarity_Uncommon) {
                    if (window[i].joker.joker == Sixth_Sense && !sixthAnte) sixthAnte = ante;
                    if (window[i].joker.joker == Seance && !seanceAnte) seanceAnte = ante;
                }
            }
        }

        count += natural;

        // Route 2: one pending tag per joker negatived, each in its own frame.
        int pendingNeg = (carriedTag == Negative_Tag ? 1 : 0) + (slot1 == Negative_Tag ? 1 : 0);
        int negTagHits = pendingNeg < tagTargets ? pendingNeg : tagTargets;
        count += negTagHits;

        // Route 4. Judgement creates a joker whatever its rarity, so the
        // edition draw has to happen on every trigger: testing the rarity
        // first would short-circuit it away and desync the edition stream.
        int judgement = 0;
        for (int t = 0; t < ANR_JUDGEMENT_TRIGGERS; t++) {
            rarity r = next_joker_rarity(inst, S_Judgement, ante);
            if (next_joker_edition(inst, S_Judgement, ante) == Negative && r == Rarity_Rare) judgement++;
        }
        count += judgement;

        // Route 5's gate: Buffoon Packs can hold the joker too, so they are
        // walked while hunting. Once wraithAnte is set none of this runs again.
        if (hunting) {
            int packs = ante == 1 ? ANR_PACKS_ANTE1 : ANR_PACKS_LATER;
            int buffoon[ANR_PACKS_LATER > ANR_PACKS_ANTE1 ? ANR_PACKS_LATER : ANR_PACKS_ANTE1];
            int nb = 0;
            for (int p = 0; p < packs; p++) {
                pack _pack = pack_info(next_pack(inst, ante));
                if (_pack.type == Buffoon_Pack) buffoon[nb++] = _pack.size;
            }
            for (int q = 0; q < nb; q++) {
                int size = buffoon[q];
                item drawn[5];
                for (int j = 0; j < size; j++) {
                    drawn[j] = anr_uncommon_joker(inst, S_Buffoon, ante);
                    if (drawn[j] == Sixth_Sense && !sixthAnte) sixthAnte = ante;
                    if (drawn[j] == Seance && !seanceAnte) seanceAnte = ante;
                    if (drawn[j] != RETRY && !inst->params.showman) i_lock(inst, drawn[j]);
                }
                for (int j = 0; j < size; j++) if (drawn[j] != RETRY) i_unlock(inst, drawn[j]);
            }
        }
        if (!wraithAnte) {
            bool sixthReady = sixthAnte && ante >= sixthAnte + (1 - ANR_SAME_ANTE);
            bool seanceReady = seanceAnte && ante >= seanceAnte + (1 - ANR_SAME_ANTE);
            if (sixthReady && anr_wraith_in_triggers(inst, S_Sixth_Sense, ante)) wraithAnte = ante;
            else if (seanceReady && anr_wraith_in_triggers(inst, S_Seance, ante)) wraithAnte = ante;
        }
        // Route 5, from the ante the Wraith became reachable onwards.
        int wraithHits = 0;
        if (wraithAnte) {
            for (int d = 0; d < ANR_WRAITH_TRIGGERS; d++)
                if (next_joker_edition(inst, S_Wraith, ante) == Negative) wraithHits++;
        }
        count += wraithHits;

#ifdef ANR_DEBUG
        printf("ante %d tags ", ante);
        print_item(tag1); printf(" / "); print_item(tag2);
        printf(" | natural %d | negtag %d (pending %d, targets %d/%d frames)"
               " | raretag %d | combo %d | judgement %d | wraith %d (ss %d, sea %d, from %d)\n",
               natural, negTagHits, pendingNeg, tagTargets, tagFrames,
               rareTagHits, combo ? 1 : 0, judgement, wraithHits, sixthAnte, seanceAnte, wraithAnte);
#endif
        carriedTag = carryNext;
    }

    return count;
}
