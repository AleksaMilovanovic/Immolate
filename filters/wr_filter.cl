// Searches for seeds with Perkeo from The Soul in the first ante, plus a buyable Hermit or Temperance tarot in the first shop.
// This keeps the Perkeo-from-Soul requirement while removing the second-legendary requirement.
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

long filter(instance* inst) {
    int soulCount = 0;
    next_pack(inst, 1); // The first shop pack is always a Buffoon Pack in this setup.

    // First shop pack must contain The Soul and it must award Perkeo.
    for (int packIndex = 1; packIndex <= 1; packIndex++) {
        pack _pack = pack_info(next_pack(inst, 1));
        item cards[5];

        if (_pack.type == Arcana_Pack) {
            arcana_pack(cards, _pack.size, inst, 1);
        } else if (_pack.type == Spectral_Pack) {
            spectral_pack(cards, _pack.size, inst, 1);
        } else {
            continue;
        }

        for (int i = 0; i < _pack.size; i++) {
            if (cards[i] == The_Soul) {
                if (next_joker(inst, S_Soul, 1) != Perkeo) {
                    return 0;
                }
                soulCount++;
            }
        }
    }
    if (soulCount == 0) {
        return 0;
    }

    bool foundBrainstorm = false;
    bool foundBlueprint = false;

    for (int ante = 1; ante <= 2; ante++) {
        int shopItems = (ante == 1) ? 4 : 10;
        for (int i = 1; i <= shopItems; i++) {
            shopitem shopItem = next_shop_item(inst, ante);
            /* int rerollIndex = 0;
            while (shopItem.type == ItemType_Joker && should_reroll_joker(shopItem.value)) {
                rerollIndex++;
                if (rerollIndex % 2 == 1) {
                    shopItem = reroll_shop_item(inst, ante, 2);
                } else {
                    shopItem = reroll_shop_item(inst, ante, 3);
                }
            } */

            if (shopItem.type == ItemType_Joker) {
                if (shopItem.value == Brainstorm) foundBrainstorm = true;
                if (shopItem.value == Blueprint) foundBlueprint = true;
            }
        }

        int packs = (ante == 1) ? 3 : 6;
        for (int p = 1; p <= packs; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            jokerdata jokers[5];

            if (_pack.type == Buffoon_Pack) {
                buffoon_pack_detailed(jokers, _pack.size, inst, ante);
                for (int j = 0; j < _pack.size; j++) {
                    /*if (should_reroll_joker(jokers[j].joker)) {
                        continue;
                    }*/
                    if (jokers[j].joker == Brainstorm) foundBrainstorm = true;
                    if (jokers[j].joker == Blueprint) foundBlueprint = true;
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
            shopitem shopItem = next_shop_item(inst, ante);
            if (shopItem.type == ItemType_Joker) {
                if (shopItem.value == Diet_Cola) {
		    dietColaCount++;
		    continue;
		}
                if (shopItem.joker.edition == Negative  && (shopItem.value == Brainstorm || shopItem.value == Blueprint)) negativeCopyJokerCount++;
            }
        }

        // Also check all packs for the previous
        for (int p = 1; p <= 6; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            jokerdata jokers[5];

            if (_pack.type == Buffoon_Pack) {
                buffoon_pack_detailed(jokers, _pack.size, inst, ante);
                for (int j = 0; j < _pack.size; j++) {
                    if (jokers[j].joker == Diet_Cola) {
                        dietColaCount++;
			continue;
                    }
                    if (jokers[j].edition == Negative && (jokers[j].joker == Brainstorm || jokers[j].joker == Blueprint)) {
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
