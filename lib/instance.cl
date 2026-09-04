// Contains settings used for different packs
// Level means level of the voucher, level 0 -> no voucher, level 1 -> base voucher, level 2 -> upgraded voucher
typedef struct InstanceParameters {
    item deck;
    item stake;
    bool vouchers[32];
    bool showman;

    item deckCards[52];
    int deckSize;
    int handSize;
} instance_params;

// Instance
#define LOCKED_WORDS ((ITEMS_END + 63) / 64)
typedef struct GameInstance {
    seed seed;
    cache rngCache;
    double hashedSeed;
    lrandom rng;
    // Bitset over the item enum: one bit per item instead of one bool.
    ulong locked[LOCKED_WORDS];
    instance_params params;
} instance;

// locked[] accessors. Semantically identical to the old bool array.
inline bool i_locked(instance* inst, item i) {
    return (inst->locked[(int)i >> 6] >> ((int)i & 63)) & 1UL;
}
inline void i_lock(instance* inst, item i) {
    inst->locked[(int)i >> 6] |= 1UL << ((int)i & 63);
}
inline void i_unlock(instance* inst, item i) {
    inst->locked[(int)i >> 6] &= ~(1UL << ((int)i & 63));
}
instance i_new(seed s) {
    // Deliberately no aggregate initializer: `instance inst = {...}` zero-fills
    // the entire ~4 KB struct every seed, most of which is the RNG node cache.
    // Cache nodes are only ever read at indices below nextFreeNode and are
    // fully written by init_node/get_node_child first, so they need no init.
    instance inst;
    inst.seed = s;
    inst.hashedSeed = pseudohash_seed(&s);
    inst.rngCache.generatedFirstPack = false;
    inst.rngCache.reportedOverflow = false;
    inst.rngCache.nextFreeNode = 0;
    // rng is only consumed after a seeded call, but keep the old zeroed state
    // for any filter that reads it first.
    inst.rng.state = (ulong4)(0, 0, 0, 0);
    inst.rng.out.ul = 0;
    // Old initializer was {.locked = {true}}: only locked[0] (RETRY) is true.
    for (int i = 0; i < LOCKED_WORDS; i++) {
        inst.locked[i] = 0UL;
    }
    i_lock(&inst, RETRY);
    inst.params.deck = Red_Deck;
    inst.params.stake = White_Stake;
    inst.params.showman = false;
    for (int i = 0; i < 32; i++) {
        inst.params.vouchers[i] = false;
    }
    for (int i = 0; i < 52; i++) {
        inst.params.deckCards[i] = RETRY;
    }
    inst.params.deckSize = 52;
    inst.params.handSize = 8;
    return inst;
}
double get_node_child(instance* inst, ntype nts[], int ids[], int num) {
    double temp = 0; // will store value set to node, which has some post-processing at the end
    int node_id = -1;
    // The (type, value) pairs and the depth are packed into one 64-bit key, so
    // the lookup is a single compare per cached node instead of a nested loop.
    ulong key = node_key(nts, ids, num);
    // Check if node exists
    for (int i = 0; i < inst->rngCache.nextFreeNode; i++) {
        if (inst->rngCache.nodes[i].key == key) {
            node_id = i;
            break;
        }
    }
    if (node_id == -1) {
        node_id = init_node(&(inst->rngCache), key);
        // pseudohash(name_0 + ... + name_{num-1} + seed), streamed. The hash
        // consumes the string from its last character to its first, so the
        // seed goes in first, then the components in reverse, with `pos`
        // tracking the character's position in the full string. Bit-identical
        // to concatenating and hashing; no string is ever built.
        int total = inst->seed.len;
        for (int i = 0; i < num; i++) {
            total += node_part_len(nts[i], ids[i]);
        }
        int pos = total;
        double h = 1;
        for (int i = inst->seed.len - 1; i >= 0; i--) {
            h = ph_step(h, s_char_at(&inst->seed, i), pos--);
        }
        for (int i = num - 1; i >= 0; i--) {
            h = ph_node_part_rev(h, &pos, nts[i], ids[i]);
        }
        inst->rngCache.nodes[node_id].rngState = h;
    }
    inst->rngCache.nodes[node_id].rngState = roundDigits(fract(inst->rngCache.nodes[node_id].rngState*1.72431234+2.134453429141),13);
    return (inst->rngCache.nodes[node_id].rngState + inst->hashedSeed)/2;
}
double random(instance* inst, ntype nts[], int ids[], int num) {
    if (num > 0) {
        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    return l_random(&(inst->rng));
}
double random_simple(instance* inst, rtype rt) {
    return random(inst, (__private ntype[]){N_Type}, (__private int[]){rt}, 1);
}
ulong randint(instance* inst, ntype nts[], int ids[], int num, ulong min, ulong max) {
    if (num > 0) {
        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    return l_randint(&(inst->rng), min, max);
}

item randchoice(instance* inst, ntype nts[], int ids[], int num, __constant item items[]) {//, size_t item_size) { not needed, we'll have element 1 give us the size
    if (num > 0) {
        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    return items[l_randint(&(inst->rng), 1, items[0])];
}

// The most common form of randchoice
// Now with rerolls!
item randchoice_common(instance* inst, rtype rngType, rsrc src, int ante, __constant item items[]) {
    item i = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){rngType, src, ante}, 3, items);
    if (!inst->params.showman && i_locked(inst, i)) {
        int resampleNum = 1;
        while (i_locked(inst, i)) {
            i = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample}, (__private int[]){rngType, src, ante, resampleNum}, 4, items);
            resampleNum++;
        }
    }
    return i;
}
item randchoice_resample(instance* inst, rtype rngType, rsrc src, int ante, __constant item items[], int resampleNum) {
    return randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample}, (__private int[]){rngType, src, ante, resampleNum}, 4, items);
}

item randchoice_simple(instance* inst, rtype rngType, __constant item items[]) {
    return randchoice(inst, (__private ntype[]){N_Type}, (__private int[]){rngType}, 1, items);
}

// Implementation specifically for dynamic arrays (Poker hands for Orbital Tag)
item randchoice_dynamic(instance* inst, ntype nts[], int ids[], int num, item items[]) {//, size_t item_size) { not needed, we'll have element 1 give us the size
    if (num > 0) {
        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    return items[l_randint(&(inst->rng), 1, items[0])];
}

item randchoice_simple_dynamic(instance* inst, rtype rngType, item items[]) {
    return randchoice_dynamic(inst, (__private ntype[]){N_Type}, (__private int[]){rngType}, 1, items);
}
// ==============================================================================

void randlist(item out[], int size, instance* inst, rtype rngType, rsrc src, int ante, __constant item items[]) {
    for (int i = 0; i < size; i++) {
        out[i] = randchoice_common(inst, rngType, src, ante, items);
        if (!inst->params.showman) i_lock(inst, out[i]); // temporary reroll for locked items
    }
    for (int i = 0; i < size; i++) {
        if (!inst->params.showman) i_unlock(inst, out[i]);
    }
}

item randweightedchoice(instance* inst, ntype nts[], int ids[], int num, __constant weighteditem items[]) {
    double poll = random(inst, nts, ids, num)*items[0].weight;
    int idx = 1;
    double weight = 0;
    while (weight < poll) {
        weight += items[idx].weight;
        idx++;
    }
    return items[idx-1]._item;
}

// Locks - NOT UPDATED FOR 1.0
void init_locks(instance* inst, int ante, bool fresh_profile, bool fresh_run) {
    // Locked behind antes
    if (ante < 2) {
        i_lock(inst, The_Mouth);
        i_lock(inst, The_Fish);
        i_lock(inst, The_Wall);
        i_lock(inst, The_House);
        i_lock(inst, The_Mark);
        i_lock(inst, The_Wheel);
        i_lock(inst, The_Arm);
        i_lock(inst, The_Water);
        i_lock(inst, The_Needle);
        i_lock(inst, The_Flint);
        i_lock(inst, Negative_Tag);
        i_lock(inst, Standard_Tag);
        i_lock(inst, Meteor_Tag);
        i_lock(inst, Buffoon_Tag);
        i_lock(inst, Handy_Tag);
        i_lock(inst, Garbage_Tag);
        i_lock(inst, Ethereal_Tag);
        i_lock(inst, Top_up_Tag);
        i_lock(inst, Orbital_Tag);
    }
    if (ante < 3) {
        i_lock(inst, The_Tooth);
        i_lock(inst, The_Eye);
    }
    if (ante < 4) {
        i_lock(inst, The_Plant);
    }
    if (ante < 5) {
        i_lock(inst, The_Serpent);
    }
    if (ante < 6) {
        i_lock(inst, The_Ox);
    }

    // Locked in a fresh profile
    if (fresh_profile) {
        // Tags
        i_lock(inst, Negative_Tag);
        i_lock(inst, Foil_Tag);
        i_lock(inst, Holographic_Tag);
        i_lock(inst, Polychrome_Tag);

        // Jokers
        i_lock(inst, Golden_Ticket);
        i_lock(inst, Mr_Bones);
        i_lock(inst, Acrobat);
        i_lock(inst, Sock_and_Buskin);
        i_lock(inst, Swashbuckler);
        i_lock(inst, Troubadour);
        i_lock(inst, Certificate);
        i_lock(inst, Smeared_Joker);
        i_lock(inst, Throwback);
        i_lock(inst, Hanging_Chad);
        i_lock(inst, Rough_Gem);
        i_lock(inst, Bloodstone);
        i_lock(inst, Arrowhead);
        i_lock(inst, Onyx_Agate);
        i_lock(inst, Glass_Joker);
        i_lock(inst, Showman);
        i_lock(inst, Flower_Pot);
        i_lock(inst, Blueprint);
        i_lock(inst, Wee_Joker);
        i_lock(inst, Merry_Andy);
        i_lock(inst, Oops_All_6s);
        i_lock(inst, The_Idol);
        i_lock(inst, Seeing_Double);
        i_lock(inst, Matador);
        i_lock(inst, Hit_the_Road);
        i_lock(inst, The_Duo);
        i_lock(inst, The_Trio);
        i_lock(inst, The_Family);
        i_lock(inst, The_Order);
        i_lock(inst, The_Tribe);
        i_lock(inst, Stuntman);
        i_lock(inst, Invisible_Joker);
        i_lock(inst, Brainstorm);
        i_lock(inst, Satellite);
        i_lock(inst, Shoot_the_Moon);
        i_lock(inst, Drivers_License);
        i_lock(inst, Cartomancer);
        i_lock(inst, Astronomer);
        i_lock(inst, Burnt_Joker);
        i_lock(inst, Bootstraps);

        // Vouchers
        i_lock(inst, Overstock_Plus);
        i_lock(inst, Liquidation);
        i_lock(inst, Glow_Up);
        i_lock(inst, Reroll_Glut);
        i_lock(inst, Omen_Globe);
        i_lock(inst, Observatory);
        i_lock(inst, Nacho_Tong);
        i_lock(inst, Recyclomancy);
        i_lock(inst, Tarot_Tycoon);
        i_lock(inst, Planet_Tycoon);
        i_lock(inst, Money_Tree);
        i_lock(inst, Antimatter);
        i_lock(inst, Illusion);
        i_lock(inst, Petroglyph);
        i_lock(inst, Retcon);
        i_lock(inst, Palette);
    }

    // Locked in start of run
    if (fresh_run) {
        //Require hand discoveries
        i_lock(inst, Planet_X);
        i_lock(inst, Ceres);
        i_lock(inst, Eris);
        i_lock(inst, Five_of_a_Kind);
        i_lock(inst, Flush_House);
        i_lock(inst, Flush_Five);

        //Requires specific card enhancement
        i_lock(inst, Stone_Joker); //Stone
        i_lock(inst, Steel_Joker); //Steel
        i_lock(inst, Glass_Joker); //Glass
        i_lock(inst, Golden_Ticket); //Gold
        i_lock(inst, Lucky_Cat); //Lucky

        // Requires Gros Michel death
        i_lock(inst, Cavendish);

        // Vouchers
        i_lock(inst, Overstock_Plus);
        i_lock(inst, Liquidation);
        i_lock(inst, Glow_Up);
        i_lock(inst, Reroll_Glut);
        i_lock(inst, Omen_Globe);
        i_lock(inst, Observatory);
        i_lock(inst, Nacho_Tong);
        i_lock(inst, Recyclomancy);
        i_lock(inst, Tarot_Tycoon);
        i_lock(inst, Planet_Tycoon);
        i_lock(inst, Money_Tree);
        i_lock(inst, Antimatter);
        i_lock(inst, Illusion);
        i_lock(inst, Petroglyph);
        i_lock(inst, Retcon);
        i_lock(inst, Palette);
    }
}

// Things that are unlocked when switching antes
void init_unlocks(instance* inst, int ante, bool fresh_profile) {
    if (ante == 2) {
        i_unlock(inst, The_Mouth);
        i_unlock(inst, The_Fish);
        i_unlock(inst, The_Wall);
        i_unlock(inst, The_House);
        i_unlock(inst, The_Mark);
        i_unlock(inst, The_Wheel);
        i_unlock(inst, The_Arm);
        i_unlock(inst, The_Water);
        i_unlock(inst, The_Needle);
        i_unlock(inst, The_Flint);
        if (!fresh_profile) i_unlock(inst, Negative_Tag);
        i_unlock(inst, Standard_Tag);
        i_unlock(inst, Meteor_Tag);
        i_unlock(inst, Buffoon_Tag);
        i_unlock(inst, Handy_Tag);
        i_unlock(inst, Garbage_Tag);
        i_unlock(inst, Ethereal_Tag);
        i_unlock(inst, Top_up_Tag);
        i_unlock(inst, Orbital_Tag);
    }
    if (ante == 3) {
        i_unlock(inst, The_Tooth);
        i_unlock(inst, The_Eye);
    }
    if (ante == 4) {
        i_unlock(inst, The_Plant);
    }
    if (ante == 5) {
        i_unlock(inst, The_Serpent);
    }
    if (ante == 6) {
        i_unlock(inst, The_Ox);
    }
}