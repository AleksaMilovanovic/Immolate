// Contains settings used for different packs
// Level means level of the voucher, level 0 -> no voucher, level 1 -> base voucher, level 2 -> upgraded voucher
// INSTANCE_NO_DECK drops the 52-item starting-deck array from the per-work-item
// instance. It is a private-memory footprint switch for filters that never call
// the deck path (init_deck / get_deck / anything reading params.deckCards); such
// a filter would fail to compile rather than read a missing array, so the switch
// cannot silently change results. Undefined by default: layout is unchanged.
typedef struct InstanceParameters {
    item deck;
    item stake;
    bool vouchers[32];
    bool showman;

#ifndef INSTANCE_NO_DECK
    item deckCards[52];
#endif
    int deckSize;
    int handSize;
} instance_params;

// Instance
#define LOCKED_WORDS ((ITEMS_END + 63) / 64)
// Seed-suffix hash states, indexed by node-name length (see get_node_child).
// Names run from 4 ("Tag" + ante) to ~45 characters; longer ones just recompute.
#ifndef SEED_HASH_LENS
#define SEED_HASH_LENS 48
#endif
// Entries in the name-suffix hash cache, a power of two (SUFFIX_CACHE_BITS).
#ifndef SUFFIX_CACHE_BITS
#define SUFFIX_CACHE_BITS 6
#endif
#define SUFFIX_CACHE_SIZE (1 << SUFFIX_CACHE_BITS)
// Operation counters for cost attribution. Compiled in only when the filter
// (or a diagnostics/ wrapper) defines DIAG_COUNTERS before including the lib;
// undefined by default, so the instance layout and the code are unchanged.
#ifdef DIAG_COUNTERS
typedef struct DiagCounters {
    uint nodeResolve;  // rng_node_resolve calls (one per node use)
    uint nodeCreate;   // ... of which created a new node (name hashed)
    uint lastHit;      // ... of which hit the lastNode fast path
    uint scanCmp;      // key compares done by the linear scan
    uint advance;      // rng_node_advance calls (state step in local memory)
    uint reseed;       // randomseed calls (fp64 seeding + 10 warmup steps)
    uint draw;         // l_random / l_randint calls
    uint phName;       // ph_step calls hashing node-name characters
    uint phSeed;       // ph_step calls hashing the seed for a new name length
    uint phInit;       // ph_step calls in i_init (the seed's own hash)
} diagcounters;
#define DIAG_INC(inst, f) ((inst)->diag.f++)
#define DIAG_ADD(inst, f, n) ((inst)->diag.f += (uint)(n))
#else
#define DIAG_INC(inst, f) ((void)0)
#define DIAG_ADD(inst, f, n) ((void)0)
#endif
typedef struct GameInstance {
    seed seed;
    cache rngCache;
    double hashedSeed;
    lrandom rng;
    // Bitset over the item enum: one bit per item instead of one bool.
    ulong locked[LOCKED_WORDS];
    // pseudohash state after consuming the seed characters at positions
    // L+1..L+len, for each node-name length L seen so far; bit L of
    // seedHashValid says whether entry L is filled. Every node created with a
    // name of length L reuses this instead of re-hashing the seed.
    ulong seedHashValid;
    double seedHashByLen[SEED_HASH_LENS];
    // Name-suffix hash states (see rng_node_resolve). Direct-mapped: entry
    // k holds the state after hashing the seed plus the last m parts of some
    // node name, keyed by (name length, those parts and their positions).
    ulong suffixKey[SUFFIX_CACHE_SIZE];
    double suffixState[SUFFIX_CACHE_SIZE];
    ulong suffixValid[(SUFFIX_CACHE_SIZE + 63) / 64];
#ifdef DIAG_COUNTERS
    diagcounters diag;
#endif
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
// Initialize *inst in place. The previous by-value `instance i_new(seed)`
// made the compiler hold two copies of the struct in the kernel's frame; with
// CACHE_SIZE 512 that is ~8.7 KB each, enough on its own to pin the kernel at
// 255 registers and spill regardless of how small the code is.
void i_init(instance* inst, seed s) {
    // Deliberately no aggregate initializer: `instance inst = {...}` zero-fills
    // the entire ~4 KB struct every seed, most of which is the RNG node cache.
    // Cache nodes are only ever read at indices below nextFreeNode and are
    // fully written by init_node/get_node_child first, so they need no init.
    inst->seed = s;
#ifdef DIAG_COUNTERS
    inst->diag = (diagcounters){0};
#endif
    inst->hashedSeed = pseudohash_seed(&s);
    DIAG_ADD(inst, phInit, s.len);
    inst->rngCache.generatedFirstPack = false;
    inst->rngCache.reportedOverflow = false;
    inst->rngCache.lastNode = -1;
    inst->rngCache.nextFreeNode = 0;
    inst->seedHashValid = 0UL; // entries are written before they are read
    for (int i = 0; i < (SUFFIX_CACHE_SIZE + 63) / 64; i++) {
        inst->suffixValid[i] = 0UL;
    }
    // rng is only consumed after a seeded call, but keep the old zeroed state
    // for any filter that reads it first.
    inst->rng.state = (ulong4)(0, 0, 0, 0);
    inst->rng.out.ul = 0;
    // Old initializer was {.locked = {true}}: only locked[0] (RETRY) is true.
    for (int i = 0; i < LOCKED_WORDS; i++) {
        inst->locked[i] = 0UL;
    }
    i_lock(inst, RETRY);
    inst->params.deck = Red_Deck;
    inst->params.stake = White_Stake;
    inst->params.showman = false;
    for (int i = 0; i < 32; i++) {
        inst->params.vouchers[i] = false;
    }
#ifndef INSTANCE_NO_DECK
    for (int i = 0; i < 52; i++) {
        inst->params.deckCards[i] = RETRY;
    }
#endif
    inst->params.deckSize = 52;
    inst->params.handSize = 8;
}
// Key of the name suffix made of parts j..num-1 (j >= 1) of a node whose
// packed key is `key` and whose full name has nameLen characters: node_key's
// slot layout for the kept parts, all-ones below, and slot 0 (never a real
// part of a suffix) holding 0xFF00 | nameLen.
inline ulong suffix_key(ulong key, int nameLen, int j) {
    ulong mask = ~0UL << (16 * j);
    ulong k = (key & mask) | ~mask;
    return (k & ~0xFFFFUL) | 0xFF00UL | (ulong)(nameLen & 0xFF);
}
inline uint suffix_slot(ulong sk) {
    return (uint)((sk * 0x9E3779B97F4A7C15UL) >> (64 - SUFFIX_CACHE_BITS));
}
// pseudohash state after the seed's characters when they sit at positions
// L+1..L+len of a node name of length L. The seed part depends on the name only
// through L, so it is cached per L in seedHashByLen: a filter creating N nodes
// over D distinct lengths hashes the seed D times instead of N.
double rng_seed_state(instance* inst, int nameLen) {
    bool cacheable = nameLen < SEED_HASH_LENS;
    if (cacheable && ((inst->seedHashValid >> nameLen) & 1UL)) {
        return inst->seedHashByLen[nameLen];
    }
    int spos = nameLen + inst->seed.len;
    double h = 1;
    DIAG_ADD(inst, phSeed, inst->seed.len);
    for (int i = inst->seed.len - 1; i >= 0; i--) {
        h = ph_step(h, s_char_at(&inst->seed, i), spos--);
    }
    if (cacheable) {
        inst->seedHashByLen[nameLen] = h;
        inst->seedHashValid |= 1UL << nameLen;
    }
    return h;
}
// Make sure the suffix-cache entries for parts j..num-1 (and every longer
// suffix down to j) of this name are filled, without creating the node. Called
// by randchoice_common_batch before each depth's pending loop with a
// representative name of each length in the batch, so that every lane's later
// creations of "..._resample<k>" nodes hit the shared suffix state at once
// instead of each lane paying the full hash at a different list position and
// the warp paying it at all of them. Exact: it only computes states that the
// creation path would compute identically on demand.
void rng_suffix_prewarm(instance* inst, ntype nts[], int ids[], int num, int j) {
    int nameLen = 0;
    for (int i = 0; i < num; i++) nameLen += node_part_len(nts[i], ids[i]);
    ulong key = node_key(nts, ids, num);
    ulong sk = suffix_key(key, nameLen, j);
    uint slot = suffix_slot(sk);
    if (((inst->suffixValid[slot >> 6] >> (slot & 63)) & 1UL) && inst->suffixKey[slot] == sk) return;
    double h = rng_seed_state(inst, nameLen);
    int pos = nameLen;
    for (int i = num - 1; i >= j; i--) {
        DIAG_ADD(inst, phName, node_part_len(nts[i], ids[i]));
        h = ph_node_part_rev(h, &pos, nts[i], ids[i]);
        ulong k2 = suffix_key(key, nameLen, i);
        uint s2 = suffix_slot(k2);
        inst->suffixKey[s2] = k2;
        inst->suffixState[s2] = h;
        inst->suffixValid[s2 >> 6] |= 1UL << (s2 & 63);
    }
}
// Hash a new node's name into its starting state. Kept out of line: the node
// cache hit path is inlined into every draw of kernels that already sit at the
// 128-register cap, and inlining this (rarely taken, hashing-heavy) path there
// cost deep_negative_shops ~650 bytes of spills per lane.
__attribute__((noinline))
void rng_node_hash_name(instance* inst, ulong key, rng_node_id node_id) {
    // The parts are decoded from the packed key rather than passed as arrays:
    // an out-of-line callee taking the callers' compound-literal arrays forced
    // every call site to materialise them in memory first, which cost the
    // deck filter (one node per seed, nothing to share) 2.5%.
    ntype nts[4];
    int ids[4];
    int num = 0;
    for (int i = 0; i < 4; i++) {
        ulong slot = (key >> (16 * i)) & 0xFFFFUL;
        if (slot == NODE_SLOT_EMPTY) break;
        nts[i] = (ntype)(slot >> 14);
        ids[i] = (int)(slot & 0x3FFFUL);
        num++;
    }
    // pseudohash(name_0 + ... + name_{num-1} + seed), streamed. The hash
    // consumes the string from its last character to its first, so the
    // seed goes in first, then the components in reverse, with `pos`
    // tracking the character's position in the full string. Bit-identical
    // to concatenating and hashing; no string is ever built.
    //
    // The seed part depends on the name only through its length L (the
    // seed's characters sit at positions L+1..L+len), so the state after
    // it is cached per L in seedHashByLen. This is most of the hashing on
    // every path: a filter creating N nodes over D distinct lengths hashes
    // the seed D times instead of N. Exact; only ph_steps are skipped.
    int nameLen = 0;
    for (int i = 0; i < num; i++) {
        nameLen += node_part_len(nts[i], ids[i]);
    }
    // The same reasoning extends to the name itself. The parts are hashed
    // last-first, so the state after the seed and the last m parts depends
    // only on (nameLen, those m parts): "Joker2buf3_resample7" and
    // "rarity3buf3_resample7" share the state after "3_resample7", and every
    // node of an ante shares the state after the ante digits. Those states
    // are memoised in a small direct-mapped cache keyed by the packed
    // suffix. Longest suffix first; on a miss the states are stored as they
    // are produced. Exact: the same characters at the same positions.
    // Keys and part lengths are recomputed rather than kept in arrays: the
    // caller is inlined into kernels already at the register cap, and an
    // earlier version holding skeys[4]/partLen[4] spilled ~1 KB per lane.
    int first = num; // parts first..num-1 are accounted for in h
    double h = 0;
    int pos = nameLen; // the seed's characters counted pos down to here
    for (int j = 1; j < num; j++) {
        ulong sk = suffix_key(key, nameLen, j);
        uint slot = suffix_slot(sk);
        if (((inst->suffixValid[slot >> 6] >> (slot & 63)) & 1UL) && inst->suffixKey[slot] == sk) {
            h = inst->suffixState[slot];
            for (int i = j; i < num; i++) pos -= node_part_len(nts[i], ids[i]);
            first = j;
            break;
        }
    }
    if (first == num) h = rng_seed_state(inst, nameLen);
    for (int i = first - 1; i >= 0; i--) {
        DIAG_ADD(inst, phName, node_part_len(nts[i], ids[i]));
        h = ph_node_part_rev(h, &pos, nts[i], ids[i]);
        if (i >= 1) {
            ulong sk = suffix_key(key, nameLen, i);
            uint slot = suffix_slot(sk);
            inst->suffixKey[slot] = sk;
            inst->suffixState[slot] = h;
            inst->suffixValid[slot >> 6] |= 1UL << (slot & 63);
        }
    }
    inst->rngCache.nodes[node_id].rngState = h;
}
rng_node_id rng_node_resolve(instance* inst, ntype nts[], int ids[], int num) {
    rng_node_id node_id = RNG_NODE_INVALID;
    // The (type, value) pairs and the depth are packed into one 64-bit key, so
    // the lookup is a single compare per cached node instead of a nested loop.
    ulong key = node_key(nts, ids, num);
    DIAG_INC(inst, nodeResolve);
    int lastNode = inst->rngCache.lastNode;
    if (lastNode >= 0 && inst->rngCache.nodes[lastNode].key == key) {
        node_id = lastNode;
        DIAG_INC(inst, lastHit);
    } else {
        // Recent node streams are usually reused first within the current ante.
        for (int i = inst->rngCache.nextFreeNode - 1; i >= 0; i--) {
            DIAG_INC(inst, scanCmp);
            if (inst->rngCache.nodes[i].key == key) {
                node_id = i;
                break;
            }
        }
    }
    if (node_id == RNG_NODE_INVALID) {
        node_id = init_node(&(inst->rngCache), key);
        DIAG_INC(inst, nodeCreate);
        rng_node_hash_name(inst, key, node_id);
    }
    return node_id;
}
inline double rng_node_advance(instance* inst, rng_node_id node_id) {
    DIAG_INC(inst, advance);
    inst->rngCache.lastNode = (short)node_id;
    inst->rngCache.nodes[node_id].rngState = roundDigits(fract(inst->rngCache.nodes[node_id].rngState*1.72431234+2.134453429141),13);
    return (inst->rngCache.nodes[node_id].rngState + inst->hashedSeed)/2;
}
inline double get_node_child(instance* inst, ntype nts[], int ids[], int num) {
    return rng_node_advance(inst, rng_node_resolve(inst, nts, ids, num));
}
inline double random_bound(instance* inst, rng_node_id node_id) {
    DIAG_INC(inst, reseed); inst->rng = randomseed(rng_node_advance(inst, node_id));
    DIAG_INC(inst, draw);
    return l_random(&(inst->rng));
}
double random(instance* inst, ntype nts[], int ids[], int num) {
    if (num > 0) {
        DIAG_INC(inst, reseed); inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    DIAG_INC(inst, draw);
    return l_random(&(inst->rng));
}
double random_simple(instance* inst, rtype rt) {
    return random(inst, (__private ntype[]){N_Type}, (__private int[]){rt}, 1);
}
ulong randint(instance* inst, ntype nts[], int ids[], int num, ulong min, ulong max) {
    if (num > 0) {
        DIAG_INC(inst, reseed); inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    DIAG_INC(inst, draw);
    return l_randint(&(inst->rng), min, max);
}

item randchoice(instance* inst, ntype nts[], int ids[], int num, __constant item items[]) {//, size_t item_size) { not needed, we'll have element 1 give us the size
    if (num > 0) {
        DIAG_INC(inst, reseed); inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    DIAG_INC(inst, draw);
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

// Many randchoice_common draws at once, resample chains DEPTH-MAJOR.
//
// Request i is a base draw from node (rngType, src, ante_i) followed, while the
// item is locked, by draws from (rngType, src, ante_i, "_resample" k) for
// k = 1, 2, ... -- exactly randchoice_common. The difference is scheduling:
// all base draws first, then every request still locked draws depth 1, then
// depth 2, and so on, each lane walking its own list of pending requests.
//
// Exact: RNG nodes are independent streams, so only the order of draws within
// one node matters. The base node of an ante is consumed by its requests in
// request order in both forms; resample node k of an ante is consumed by
// exactly the requests locked at every depth < k, in request order, in both.
// Requires the lock set not to change between the requests (no temporary
// locks, as packs use) and n <= RC_BATCH_MAX.
//
// Why it is faster on a 32-lane warp: request-major, a warp pays
// sum over requests of max over lanes(1 + resamples), and resamples are
// geometric, so the max over 32 lanes is several times the mean; the body of
// a resample is a node creation (~0.4 ns after the suffix cache) plus a draw.
// Depth-major pays sum over depths of max over lanes(pending count), and
// those counts are binomial, so they concentrate near the mean.
// `antes` may be NULL, in which case every request uses `ante0`.
#ifndef RC_BATCH_MAX
#define RC_BATCH_MAX 512
#endif
void randchoice_common_batch(instance* inst, rtype rngType, rsrc src, const int antes[], int ante0, int n,
                             __constant item items[], item out[]) {
    ushort pend[RC_BATCH_MAX];
    int np = 0;
    const bool showman = inst->params.showman;
    // One representative ante per digit count: the "_resample<k>" suffix state
    // depends on the name length only, so pre-warming it for these makes every
    // lane's resample-node creations at that depth hit the cache (see
    // rng_suffix_prewarm). Depths 1 and 2 only; deeper ones have too few
    // pending requests for the warp-wide pre-warm to pay for itself.
    int ex1 = -1, ex2 = -1;
    for (int i = 0; i < n; i++) {
        int ante = antes ? antes[i] : ante0;
        if (ante < 10) ex1 = ante; else ex2 = ante;
        out[i] = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){rngType, src, ante}, 3, items);
        if (!showman && i_locked(inst, out[i])) pend[np++] = (ushort)i;
    }
    for (int depth = 1; np > 0; depth++) {
        if (depth <= 2) {
            if (ex1 >= 0) rng_suffix_prewarm(inst, (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample}, (__private int[]){rngType, src, ex1, depth}, 4, 3);
            if (ex2 >= 0) rng_suffix_prewarm(inst, (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample}, (__private int[]){rngType, src, ex2, depth}, 4, 3);
        }
        int np2 = 0;
        for (int j = 0; j < np; j++) {
            int i = pend[j];
            int ante = antes ? antes[i] : ante0;
            out[i] = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample}, (__private int[]){rngType, src, ante, depth}, 4, items);
            if (i_locked(inst, out[i])) pend[np2++] = (ushort)i; // np2 <= j: compacting in place is safe
        }
        np = np2;
    }
}

item randchoice_simple(instance* inst, rtype rngType, __constant item items[]) {
    return randchoice(inst, (__private ntype[]){N_Type}, (__private int[]){rngType}, 1, items);
}

// Implementation specifically for dynamic arrays (Poker hands for Orbital Tag)
item randchoice_dynamic(instance* inst, ntype nts[], int ids[], int num, item items[]) {//, size_t item_size) { not needed, we'll have element 1 give us the size
    if (num > 0) {
        DIAG_INC(inst, reseed); inst->rng = randomseed(get_node_child(inst, nts, ids, num));
    }
    DIAG_INC(inst, draw);
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