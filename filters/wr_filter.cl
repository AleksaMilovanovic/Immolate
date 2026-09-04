// Searches for seeds with Perkeo from The Soul in the first ante, plus a buyable Hermit or Temperance tarot in the first shop.
// This keeps the Perkeo-from-Soul requirement while removing the second-legendary requirement.

// A seed that reaches ante 38 creates up to ~475 distinct RNG nodes (17-18 per
// ante for shop card types, rarities, editions, stickers, tarots, planets,
// packs, and pack jokers). The default cache holds 64. Beyond that, init_node
// reuses the last slot, so from about ante 6 onward every new node clobbers
// the previous one and the tallies are garbage: on 400 deep test seeds the
// 64-node diet cola count differed from the true value on every single seed
// (e.g. 9 vs 18, 0 vs 20, 201 vs 26). 512 covers the worst case observed.
#define CACHE_SIZE 512
#include "lib/immolate.cl"

/* __constant item rerollPool[] = {
Mr_Bones,
Acrobat,
Sock_and_Buskin,
Troubadour,
Certificate,
Smeared_Joker,
Throwback,
Rough_Gem,
Bloodstone,
Arrowhead,
Onyx_Agate,
Glass_Joker,
Showman,
Flower_Pot,
Merry_Andy,
Oops_All_6s,
The_Idol,
Seeing_Double,
Matador,
Satellite,
Cartomancer,
Astronomer,
Bootstraps,
Steel_Joker,
Stone_Joker
};

bool should_reroll_joker(item joker) {
    for (int i = 0; i < sizeof(rerollPool) / sizeof(rerollPool[0]); i++) {
        if (rerollPool[i] == joker) {
            return true;
        }
    }
    return false;
}

shopitem reroll_shop_item(instance* inst, int ante, int altSeedIndex) {
    double oldHashedSeed = inst->hashedSeed;
    if (altSeedIndex == 2) {
        inst->hashedSeed = inst->hashedSeed2;
    } else {
        inst->hashedSeed = inst->hashedSeed3;
    }

    shopitem item = next_shop_item(inst, ante);
    inst->hashedSeed = oldHashedSeed;
    return item;
} */

// Exact emulation of the soul polls inside arcana_pack / spectral_pack, without
// generating the tarot/spectral cards. RNG state is per node: the soul polls
// live on node soul_<Tarot|Spectral><ante>, the card draws on a different node
// that this filter never touches again, and the pack unlocks everything it
// drew before returning. So whether a Soul appears depends only on the soul
// node's draw sequence, reproduced here draw for draw, including the rule
// that a forced The_Soul / Black_Hole is locked and stops its own poll for the
// rest of the pack. Returns true if any card in the pack would be The_Soul.
#if V_AT_MOST(1,0,0,10)
    #define WR_SOUL_POLL(inst, rt, ante) random(inst, (__private ntype[]){N_Type, N_Type}, (__private int[]){R_Soul, rt}, 2)
#else
    #define WR_SOUL_POLL(inst, rt, ante) random(inst, (__private ntype[]){N_Type, N_Type, N_Ante}, (__private int[]){R_Soul, rt, ante}, 3)
#endif
bool wr_pack_has_soul(instance* inst, pack _pack, int ante) {
    bool soulLocked = i_locked(inst, The_Soul);
    bool bhLocked = i_locked(inst, Black_Hole);
    bool showman = inst->params.showman;
    if (_pack.type == Arcana_Pack) {
        for (int i = 0; i < _pack.size; i++) {
            if ((showman || !soulLocked) && WR_SOUL_POLL(inst, R_Tarot, ante) > 0.997) {
                return true;
            }
        }
        return false;
    }
    // Spectral pack: two polls per card, Black Hole's result overrides the Soul's.
    for (int i = 0; i < _pack.size; i++) {
        item forced = RETRY;
        if ((showman || !soulLocked) && WR_SOUL_POLL(inst, R_Spectral, ante) > 0.997) {
            forced = The_Soul;
        }
        if ((showman || !bhLocked) && WR_SOUL_POLL(inst, R_Spectral, ante) > 0.997) {
            forced = Black_Hole;
        }
        if (forced == The_Soul) return true;
        if (forced == Black_Hole && !showman) bhLocked = true;
    }
    return false;
}

// Shop slot reduced to what this filter reads: the joker's identity, or RETRY
// for a non-joker slot. next_shop_item also polled stickers and edition and
// drew the tarot/planet for non-joker slots; those nodes are ante-specific and
// antes 1-2 are never revisited, so skipping them changes nothing observable.
// Joker identity plus edition for a shop slot, or RETRY for a non-joker slot.
// Compared with next_shop_item this skips (a) the tarot/planet identity draw for
// non-joker slots, and (b) the eternal/perishable sticker poll and the rental
// poll inside next_joker_with_info. Each of those lives on its own RNG node
// (Tarot/Planet + source + ante; etperpoll + ante; ssjr + ante) that nothing in
// this filter ever reads, and the sticker/rental results can only be non-empty
// at Black Stake or above while this filter runs at White Stake. Skipping them
// therefore changes no value this filter observes. The draws that ARE kept
// (card type, rarity, joker, edition) happen in the same order as before.
item wr_shop_joker_edition(instance* inst, int ante, item* edition) {
    shop shopInstance = get_shop_instance(inst);
    double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * get_total_rate(shopInstance);
    if (get_item_type(shopInstance, card_type) != ItemType_Joker) return RETRY;
    item joker = next_joker(inst, S_Shop, ante);
    *edition = next_joker_edition(inst, S_Shop, ante);
    return joker;
}
// buffoon_pack_detailed without the sticker and rental polls (see above). Same
// joker draws in the same order, same temporary locks between them, same
// edition polls; only the polls this filter cannot observe are gone.
void wr_buffoon_pack(item jokers[], item editions[], int size, instance* inst, int ante) {
    for (int i = 0; i < size; i++) {
        jokers[i] = next_joker(inst, S_Buffoon, ante);
        editions[i] = next_joker_edition(inst, S_Buffoon, ante);
        if (!inst->params.showman) i_lock(inst, jokers[i]); // temporary reroll for locked items
    }
    for (int i = 0; i < size; i++) {
        i_unlock(inst, jokers[i]);
    }
}

item wr_shop_joker(instance* inst, int ante) {
    shop shopInstance = get_shop_instance(inst);
    double card_type = random(inst, (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2) * get_total_rate(shopInstance);
    if (get_item_type(shopInstance, card_type) != ItemType_Joker) return RETRY;
    return next_joker(inst, S_Shop, ante);
}

// Gate 1: the first shop pack must contain The Soul and it must award Perkeo.
// About 0.07% of seeds pass. Shared by prefilter() and filter().
bool wr_gate1(instance* inst) {
    next_pack(inst, 1); // The first shop pack is always a Buffoon Pack in this setup.
    pack firstPack = pack_info(next_pack(inst, 1));
    if (firstPack.type != Arcana_Pack && firstPack.type != Spectral_Pack) {
        return false;
    }
    if (!wr_pack_has_soul(inst, firstPack, 1)) {
        return false;
    }
    return next_joker(inst, S_Soul, 1) == Perkeo;
}

// Two-pass search (see search.cl). Pass 1 runs only this on every seed; pass 2
// runs filter() from scratch on the seeds that passed, packed together. This
// filter's cost varies ~100x between a gate-1 reject and a full ante-38 run,
// so in a single pass most lanes in a warp sit idle waiting for the one deep
// seed; splitting removes that. Only gate 1 is here: adding gate 2 would cut
// pass-2 volume another 1000x but make pass 1 itself divergent (0.07% of
// lanes running 14 shop items + 9 packs while the rest wait), and pass 2 is
// already a tiny fraction of the total.
#define HAS_PREFILTER
// WR_PREFILTER_LEVEL 1: pack type only (one node, one draw, uniform across
// lanes; passes 33% of seeds to pass 2). Level 2: all of gate 1 (passes
// 0.07%, but lanes diverge on the soul polls and the Perkeo draw).
// Measured on an RTX 5080 over 500M seeds: level 1 3.65 s, level 2 4.0 s.
#ifndef WR_PREFILTER_LEVEL
#define WR_PREFILTER_LEVEL 1
#endif
bool prefilter(instance* inst) {
#if WR_PREFILTER_LEVEL == 1
    next_pack(inst, 1);
    pack firstPack = pack_info(next_pack(inst, 1));
    return firstPack.type == Arcana_Pack || firstPack.type == Spectral_Pack;
#else
    return wr_gate1(inst);
#endif
}

// Everything after gate 1, kept out of line on purpose. Inlined into filter()
// this loop pushed the whole kernel to 255 registers with ~20 KB of spill
// traffic per seed and made the compiler emit random() as an out-of-line
// function that spills 7.8 KB on every draw, so gate 1 (which runs on every
// seed) paid for code that runs on 0.07% of seeds. As a separate function the
// hot path compiles small; the call cost lands only on the seeds that need it.
__attribute__((noinline))
long wr_deep(instance* inst) {
    bool foundBrainstorm = false;
    bool foundBlueprint = false;

    for (int ante = 1; ante <= 2; ante++) {
        int shopItems = (ante == 1) ? 4 : 10;
        for (int i = 1; i <= shopItems; i++) {
            item joker = wr_shop_joker(inst, ante);
            /* Reroll logic previously lived here; see the commented block above. */
            if (joker == Brainstorm) foundBrainstorm = true;
            if (joker == Blueprint) foundBlueprint = true;
        }

        int packs = (ante == 1) ? 3 : 6;
        for (int p = 1; p <= packs; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            item jokers[5];

            if (_pack.type == Buffoon_Pack) {
                buffoon_pack(jokers, _pack.size, inst, ante);
                for (int j = 0; j < _pack.size; j++) {
                    if (jokers[j] == Brainstorm) foundBrainstorm = true;
                    if (jokers[j] == Blueprint) foundBlueprint = true;
                }
            }
        }
    }

    int copyJokerCount = (int)foundBrainstorm + (int)foundBlueprint;
    if (copyJokerCount != 2) {
        return 0;
    }

    // Tag gate first - not many negative tags means run is impossible. Call it <3 total 1st tags as impossible.
    int firstNegativeTagCount = 0;
    int secondNegativeTagCount = 0;
    for (int ante = 3; ante <= 38; ante++) {
        // Check tags and add
        item firstTag = next_tag(inst, ante);
        if (firstTag == Negative_Tag) {
            firstNegativeTagCount++;
        }

        item secondTag = next_tag(inst, ante);
        if (secondTag == Negative_Tag) {
            secondNegativeTagCount++;
        }
    }
    if (firstNegativeTagCount < 3) {
        return 0;
    }


    int negativeCopyJokerCount = 0;
    int dietColaCount = 0;
    int shopSizes[] = {10,20,50,100,150,150,150,200,200,200,250,250,250,250,250,250,250,250,250,250,300,300,300,300,300,300,300,300,300,300,350,350,350,350,350,350,350,350};

    for (int ante = 3; ante <= 38; ante++) {
	// Quick escape gates
	if (ante >= 10 &&
	    negativeCopyJokerCount == 0 &&
	    dietColaCount < 3
		) {
             return 0;
	}

	if (ante >= 15 &&
	    negativeCopyJokerCount == 0 &&
	    dietColaCount < 9
		) {
             return 0;
	}

	if (ante >= 20 &&
	    negativeCopyJokerCount == 0 &&
	    dietColaCount < 12
		) {
             return 0;
	}


        // Shop checks for diet colas and naturally negative copy jokers
        int shopItems = shopSizes[ante - 3];
        for (int i = 1; i <= shopItems; i++) {
            item edition = No_Edition;
            item joker = wr_shop_joker_edition(inst, ante, &edition);
            if (joker == RETRY) continue;
            if (joker == Diet_Cola) {
                dietColaCount++;
                continue;
            }
            if (edition == Negative && (joker == Brainstorm || joker == Blueprint)) negativeCopyJokerCount++;
        }

        // Also check all packs for the previous
        for (int p = 1; p <= 6; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            item jokers[5];
            item editions[5];

            if (_pack.type == Buffoon_Pack) {
                wr_buffoon_pack(jokers, editions, _pack.size, inst, ante);
                for (int j = 0; j < _pack.size; j++) {
                    if (jokers[j] == Diet_Cola) {
                        dietColaCount++;
                        continue;
                    }
                    if (editions[j] == Negative && (jokers[j] == Brainstorm || jokers[j] == Blueprint)) {
                        negativeCopyJokerCount++;
                    }
                }
            }
        }
    }

    // CC12DDD
    // [2NegCop][1NegTag][1NegTag2][3Diet]
    return dietColaCount + (secondNegativeTagCount * 1000) + (firstNegativeTagCount * 10000) + (negativeCopyJokerCount * 1000000);
}

long filter(instance* inst) {
    if (!wr_gate1(inst)) {
        return 0;
    }

    return wr_deep(inst);
}
