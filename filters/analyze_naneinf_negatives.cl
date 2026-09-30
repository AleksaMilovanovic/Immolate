// Plans a naneinf shop line: negative copy jokers taken naturally, plus the
// Negative Tag / Diet Cola trick, searched over every way of spending the tags.
//
// GOAL. Everything scored here has to be slot-free, because the build is a
// Blueprint/Brainstorm chain multiplying Baron (x1.5 per King held) retriggered
// by Mime. Negative costs no joker slot, so the chain is unbounded; a natural
// copy joker that is not Negative is worth nothing to it.
//   negative Blueprint / Brainstorm      +100
//   negative Baron / Mime / Burglar / DNA  +5
//   negative Juggler / Drunkard            +1   (only with ANN_SCORE_COMMONS)
//   every other negative                    0   (Uncommons still shrink the pool)
//
// ETERNAL ONLY (-D ANN_ETERNAL_ONLY, or -f analyze_naneinf_eternal). Only
// Blueprint, Brainstorm, Baron and Mime score, and only when they are BOTH
// Negative and Eternal; a Negative joker without the sticker scores nothing.
// Weights are unchanged (copy +100, Baron/Mime +5), so the score reads as
// eternal negative copy jokers x100 plus eternal negative Baron/Mime x5. The
// cola engine is untouched -- negative Uncommons are still kept to shrink the
// pool whatever their stickers -- but farming follows the sticker rather than
// the edition: an Eternal copy joker cannot be sold, so a non-Negative one is
// never bought and farms nothing, and a Negative one without the sticker is
// worth nothing to the score, so it is sold for its Double Tag like any other.
// Only a Negative Eternal copy joker is kept and stops farming for its kind.
// First-slot copy windows are aimed at Eternal copy jokers.
//
// Negative Uncommons are only bought WITHOUT the sticker, so they can be sold
// later; an Eternal one is passed over and stays in the pool. Mime is the
// exception, being a target. Diet Cola needs no such rule: the game never
// makes it Eternal.
//
// Assumes Black Stake or higher: below it the game never applies the Eternal
// sticker and every seed scores 0. The sticker comes from one poll per joker,
// in queue order, off "etperpoll"+ante in the shop and "packetper"+ante in
// Buffoon packs, above 0.7 -- the same draw lib/functions.cl makes. All four
// targets are eternal-compatible.
//
// SHOP MODEL. Identical to filters/deep_negative_shops.cl: same frame counts,
// same frame sizes, same voucher handling, same joker lock lists. See that
// file's header for the reasoning; only the differences are documented here.
//
// DIET COLAS. A Diet Cola is sold on sight for a free Double Tag, so it never
// stays owned and never leaves the Uncommon pool; ann.colas counts how many
// Double Tags are banked. A Negative Tag chained through them turns
// 1 + colas consecutive shop jokers Negative, and spending it resets colas to 0.
// Negative Uncommons, by contrast, are KEPT -- they are free -- so each one is
// locked as soon as it is seen, which shrinks the Uncommon pool and raises Diet
// Cola's share of it. That is the whole engine: negative Uncommons buy colas,
// colas buy wider Negative Tags, wider tags buy more negative Uncommons.
//
// COPY JOKERS ARE OWNED. Outside a Negative Tag window Blueprint and Brainstorm
// are locked -- one of each is already held, and without Showman the shop and
// the Buffoon packs resample past them. Inside a window Showman is held, from
// the window's first card to its last, so there they are unlocked and can show
// up again. That is per shop card, which ann_flush_pool handles with an `open`
// mask over the Rare ordinals. A first-slot window is chosen off a scouting
// draw of the Rares with Showman held for the whole ante -- where copy jokers
// WOULD show up -- and, as with everything else, only the committed walk is
// scored. The other Rares are never locked.
//
// TAG SPENDING. Per ante the options are, and never more than one of:
//   T1_COPY  first-slot Negative Tag, window = the first half of the ante's
//            shop cards, start chosen to maximise copy jokers in the window.
//   T1_UNC   same window, start chosen to maximise Uncommons. Valid only at
//            ante <= ANN_UNCOMMON_GATE_ANTE and only when at least half the
//            negatives it would make are Uncommons -- below that the pool
//            barely shrinks and the tag is better banked.
//   T2       second-slot Negative Tag. The colas are sold and the tag is
//            chained the moment it is taken, so its width is 1 + colas as of
//            the END of this ante and colas resets here; it then fires in the
//            NEXT ante over that many eligible jokers from the start of that
//            ante's queue. Diet Colas from the next ante's packs arrive too
//            late for it and start a fresh count. Worth taking only if a
//            base-edition Blueprint or Brainstorm is inside the window.
//   NONE     bank the colas. Frequently the best line: holding through two
//            antes can double the width of a later tag.
// A T2 window and the following ante's T1 window can both land in that ante;
// they are taken in order and the T1 search starts after the T2 window, since
// everything before it is already Negative.
//
// An eligible target is a shop joker with no edition at all -- Foil,
// Holographic, Polychrome and already-Negative jokers are passed over without
// consuming a tag, consumables likewise.
//
// SEARCH. Locking diverges the draw stream, so the branches genuinely see
// different shops and cannot be collapsed into one walk. They are explored as a
// depth-first tree over the antes that offer a Negative Tag, and only the best
// leaf is reported. This is affordable because no RNG state crosses an ante
// boundary (every reachable node is ante-keyed and the cache is reset per ante,
// as in deep_negative_shops), so a branch snapshot is just the lock bitset, the
// voucher flags and a few counters -- about 140 bytes -- and re-entering an ante
// from one reproduces its draws bit for bit.
//
// What diverges is narrower than "the shop", though, and the difference is
// worth about half the run time. Locks are consulted in exactly one place: when
// a drawn identity is rejected and resampled. Which cards are Jokers, their
// rarities and their editions come off three ante-keyed nodes that never look
// at the lock set, so they are the same in every branch and are drawn once per
// ante and cached -- see the ann_skel block below.
//
// The tree is also splittable across the lanes of a work-group, since the
// branches are independent: --group_per_seed, and the GROUP_PER_SEED block at
// the bottom of this file. Cache and lanes together were 7.4x on a 17-branch-
// point seed at ANN_LAST_ANTE=26 (108.4 s -> 14.7 s).
//
// The tag layout itself is choice-independent: tags are drawn from their own
// ante-keyed nodes against tag locks only, and nothing this filter locks is a
// tag. So one cheap pre-pass finds every branch point before the search starts.
//
// SCORE. The flat weighted total of the best leaf. A seed with more than
// ANN_MAX_BRANCH_POINTS branch points is not searched and returns
// ANN_OVER_BUDGET + branchPoints (>= 1000000000, far above any real score) so
// it prints under any cutoff and can be pulled out and looked at by hand.
//
// For the strategy behind a seed's score, run the explain wrapper on it:
//   immolate -f analyze_naneinf_explain -s SEED -n 1 -g 1 -c 0
// NODE BUDGET. Much larger than deep_negative_shops needs, and the reason is
// the whole point of the filter. randchoice_common puts each resample depth on
// its OWN rng node, so the per-ante node count tracks the deepest resample
// chain that ante takes. As the cola engine locks Uncommons away, the pool of
// 44 available Uncommons shrinks, the chain gets longer, and the node count
// climbs with it. Measured over 800 stratified seeds at ante 3-38: per-ante
// peak p50 61, p90 296, p99 508 -- but the tail is exponential with a scale of
// about 66 (the full Uncommon pool), because a draw against a nearly empty pool
// resamples ~66 times, so no cache this side of the stack limit makes overflow
// unreachable the way 256 does for deep_negative_shops.
//
// 2048 is the largest that is stable: at 4096 the 64KB instance overflows a
// work-item stack and pocl takes SIGBUS. An overflow past 2048 is therefore
// possible, and it lands hardest on the runaway seeds that are worth keeping --
// so it is reported as ANN_CACHE_OVERFLOW rather than silently mis-scored, and
// ANN_LOCK_FLOOR is the lever that prevents it outright.
#ifndef CACHE_SIZE
#define CACHE_SIZE 2048
#endif
#include "lib/immolate.cl"

#ifndef ANN_FIRST_ANTE
#define ANN_FIRST_ANTE 3
#endif
#ifndef ANN_LAST_ANTE
#define ANN_LAST_ANTE 38
#endif
#ifndef ANN_PACKS
#define ANN_PACKS 6
#endif
// Antes past this no longer pay back a pool-shrinking tag: there is not enough
// run left for the extra Diet Colas to arrive and be spent.
#ifndef ANN_UNCOMMON_GATE_ANTE
#define ANN_UNCOMMON_GATE_ANTE 25
#endif
// Past this many branch points the seed is parked rather than searched.
//
// Read it as a wall-clock budget, because cost is exponential in it: a branch
// point is worth 2, 3 or 4 (4 when BOTH of an ante's tag slots are Negative),
// so 17 is up to 4^17 leaves. A real one measured at 15.1 million leaves and
// roughly 44 million ante walks -- well over a day on one work-item, a few
// hours with --group_per_seed. 12 keeps a seed inside a minute or two. Use
// diagnostics/naneinf_branch_tree.cl to see what a seed would actually cost
// before committing to it.
#ifndef ANN_MAX_BRANCH_POINTS
#define ANN_MAX_BRANCH_POINTS 17
#endif
#if defined(ANN_EXPLAIN) && defined(GROUP_PER_SEED)
// Explaining a seed whose tree is split across the lanes needs the group to
// agree on which lane actually won before anyone prints -- otherwise every lane
// reports its own share's best line and the output is several interleaved
// strategies with no way to tell which is the answer. The kernel hands the
// filter its work-group scratch array for exactly this; see search.cl.
#define FILTER_USES_GROUP_SCRATCH

// Elect the lane holding the largest value. Every lane returns the same index,
// so no broadcast of the decision is needed. Ties go to the lowest lane, which
// keeps the printed line reproducible across runs.
inline int ann_group_argmax(__local long* scratch, int lane, int lanes, long mine) {
    barrier(CLK_LOCAL_MEM_FENCE);
    scratch[lane] = mine;
    barrier(CLK_LOCAL_MEM_FENCE);
    int best = 0;
    for (int i = 1; i < lanes; i++) if (scratch[i] > scratch[best]) best = i;
    return best;
}

// Largest value across the group, for folding each lane's partial altBest into
// the whole tree's. One entry at a time: altBest is at most 68 longs and the
// scratch array is only one long per lane, and this runs once per seed.
inline long ann_group_max(__local long* scratch, int lane, int lanes, long mine) {
    barrier(CLK_LOCAL_MEM_FENCE);
    scratch[lane] = mine;
    barrier(CLK_LOCAL_MEM_FENCE);
    long m = scratch[0];
    for (int i = 1; i < lanes; i++) if (scratch[i] > m) m = scratch[i];
    return m;
}
#endif

#define ANN_OVER_BUDGET 1000000000L
// A cache overflow leaves that seed's score quietly wrong, and it is likeliest
// on exactly the seeds worth keeping (see the NODE BUDGET note). Report it as a
// distinct sentinel instead of returning a corrupt number.
#define ANN_CACHE_OVERFLOW 2000000000L

// Stop locking Uncommons once this few are left in the pool. 0 is the model as
// specified -- every negative Uncommon is kept forever, so the pool can fall to
// the single Uncommon that is never locked (Diet Cola, always sold) and every
// Uncommon draw then resamples its way there, which is what drives the node
// budget above. Raising it to, say, 8 bounds the resample chain at roughly
// 66/8 and puts the per-ante node count back into the low hundreds, at the cost
// of modelling a player who stops keeping negative Uncommons near the floor.
// Set it if ANN_CACHE_OVERFLOW starts showing up in a real pool.
#ifndef ANN_LOCK_FLOOR
#define ANN_LOCK_FLOOR 0
#endif

#define ANN_W_COPY 100
#define ANN_W_FIVE 5
#define ANN_W_ONE  1

// Juggler and Drunkard are Common, and deep_negative_shops skips Common shop
// identities entirely -- an exact elision worth 0.817x, because no Common
// identity can change its score. Scoring them at +1 costs that back. Off by
// default; -D ANN_SCORE_COMMONS turns it on, with the stream truncated after
// the last ordinal whose identity can still matter (also exact: the Common
// identity node and its resample chain are read by nothing else and are
// discarded at the ante boundary).
// #define ANN_SCORE_COMMONS
#if defined(ANN_ETERNAL_ONLY) && defined(ANN_SCORE_COMMONS)
#error "ANN_ETERNAL_ONLY scores no Commons; drop ANN_SCORE_COMMONS"
#endif

// SHOWMAN. Bought before a copy-joker window and sold on the frame boundary
// after the last copy joker, so the window can take duplicates of copy jokers
// already owned. It is modelled ONLY as that: Blueprint and Brainstorm are
// unlocked over the window's span (see COPY JOKERS ARE OWNED above), and the
// explain output says which frames to buy and sell on.
//
// params.showman is not used for it. It suppresses ALL resampling, including
// the Uncommon resampling the cola engine runs on, so switching it on inside a
// window would stop the pool shrinking exactly where the model wants it to. It
// would also make a window's Uncommons depend on where the window starts, which
// is circular -- the start is chosen by reading them.

// Worst case is ante 38: 231 frames x 4 cards = 924, every one a Joker.
#define ANN_MAX_CARDS 924

__constant item ANN_LOCKED_COMMONS[] = {
    Golden_Ticket, Swashbuckler, Hanging_Chad, Shoot_the_Moon
};
__constant item ANN_LOCKED_UNCOMMONS[] = {
    Mr_Bones, Acrobat, Sock_and_Buskin, Troubadour, Certificate, Smeared_Joker, Throwback,
    Rough_Gem, Bloodstone, Arrowhead, Onyx_Agate, Glass_Joker, Showman, Flower_Pot, Merry_Andy,
    Oops_All_6s, The_Idol, Seeing_Double, Matador, Satellite, Cartomancer, Astronomer, Bootstraps
};
__constant item ANN_LOCKED_RARES[] = {
    Blueprint, Wee_Joker, Hit_the_Road, The_Duo, The_Trio, The_Family, The_Order, The_Tribe,
    Stuntman, Invisible_Joker, Brainstorm, Drivers_License, Burnt_Joker
};
__constant item ANN_UNLOCKED_COMMONS[] = {};
__constant item ANN_UNLOCKED_UNCOMMONS[] = {Showman};
// Blueprint and Brainstorm stay locked: they are owned, and a Negative Tag
// window's Showman unlocks them card by card.
__constant item ANN_UNLOCKED_RARES[] = {};
// Same list and handling as filters/negative_tags.cl and deep_negative_shops.cl.
__constant item ANN_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };

#define ANN_APPLY(list, fn) for (int _i = 0; _i < (int)(sizeof(list) / sizeof(item)); _i++) fn(inst, list[_i]);

__constant item ANN_BOUGHT_VOUCHERS[] = {
    Overstock, Overstock_Plus, Clearance_Sale, Liquidation, Reroll_Surplus, Reroll_Glut,
    Telescope, Observatory, Grabber, Nacho_Tong, Wasteful, Recyclomancy, Seed_Money, Money_Tree,
    Blank, Antimatter, Directors_Cut, Retcon, Paint_Brush, Palette, Hieroglyph, Petroglyph
};
__constant item ANN_UPGRADE_VOUCHERS[] = {
    Overstock_Plus, Liquidation, Glow_Up, Reroll_Glut, Omen_Globe, Observatory, Nacho_Tong,
    Recyclomancy, Tarot_Tycoon, Planet_Tycoon, Money_Tree, Antimatter, Illusion, Petroglyph, Retcon, Palette
};

int ann_frames(int ante) {
    if (ante <= 3) return 30;
    if (ante <= 10) return 80 + 3 * (ante - 4);
    if (ante <= 15) return 100 + 4 * (ante - 11);
    return 116 + 5 * (ante - 15);
}

// ---------------------------------------------------------------------------
// Scalar node access, as in deep_negative_shops: hoist one node's state into a
// register and consume it densely. Only ever used on nodes no lib call touches
// while the state is out.
// ---------------------------------------------------------------------------
inline double ann_advance(instance* inst, double* state) {
    *state = roundDigits(fract(*state * 1.72431234 + 2.134453429141), 13);
    return (*state + inst->hashedSeed) / 2;
}
inline double ann_random(instance* inst, double* state, lrandom* scratch) {
    *scratch = randomseed(ann_advance(inst, state));
    return l_random(scratch);
}

// What the winning line did at one branch point. `items` names the scoring
// jokers the window actually turned Negative -- what the line is aiming for.
#define ANN_LOG_ITEMS 12
typedef struct AnnLog {
    int ante, choice, width, startCard, copies, uncommons, colas, nitems, points;
    int lastCopyCard, frameSize;
    short items[ANN_LOG_ITEMS];
} ann_log;

// Running totals that a branch carries across antes.
typedef struct AnnCtx {
#ifdef ANN_PROFILE
    // Counters, not branch state: they survive a restore like nodePeak so a
    // whole seed's totals accumulate across the tree.
    long draws, depths, passes, antes;
#endif
#ifdef ANN_NODE_PEAK
    int nodePeak;   // measurement only; deliberately survives a branch restore
#endif
    int colas;
    int copies, fives, ones;
#ifdef ANN_EXPLAIN
    // Where every Double Tag came from, over the whole line, for the printout:
    // Diet Colas from packs and from the shop, then farming -- a copy joker
    // sold that was not Negative, and one that was Negative but is sold anyway
    // (ANN_ETERNAL_ONLY, no sticker). skipEternal counts copy jokers passed
    // over because the sticker means they could never be sold. noTemplate and
    // noFarm count sellable copy jokers that farmed nothing: before the first
    // Diet Cola, and after a kept Negative one of that kind shut farming off.
    int srcPack, srcShop, srcFarm, srcFarmNeg, skipEternal, noTemplate, noFarm;
#endif
    bool seenCola;       // a Diet Cola has been met, so a template exists to copy
    bool negBlueprint;   // a Negative one of this kind is owned, so it is kept
    bool negBrainstorm;  //   rather than sold -- farming stops for that kind
    int pendingWidth;    // a T2 tag taken last ante fires this ante at this width
    ann_log* pendingLog; // that tag's own log, so its score is reported there
    int uncAvail;       // Uncommons still in the pool, for ANN_LOCK_FLOOR
    bool overstock, overstockPlus;
#ifdef ANN_DOM_AUDIT
    // Why dominance pruning loses score. Counters, not branch state: they
    // survive a restore so a whole seed's totals accumulate across the tree.
    long audPrune;          // branches dropped as dominated
    long audPruneSameLock;  //   ...of those, with the SAME lock set as the dominator
    long audT1NoFit;        // T1 refused because no window of that width fits
    long audT1NoFitWide;    //   ...of those, with width > 1, i.e. colas caused it
    long audUncGateWide;    // T1_UNC refused by 2*unc < width, with width > 1
#endif
} ann_ctx;

// ---------------------------------------------------------------------------
// Identity draws that do not grow the node cache.
//
// randchoice_common puts every resample depth on its own rng node, and
// rng_node_resolve finds a node by LINEAR SCAN over all live nodes -- so a chain
// reaching depth D costs O(D^2) and leaves D nodes behind it. As the cola engine
// draws the Uncommon pool down, D runs into the hundreds, and that is both the
// node-cache overflow and most of the runtime. Worse, once the cache overflows
// nextFreeNode sticks at CACHE_SIZE and EVERY later lookup scans the whole
// array, so a bigger cache makes the collapse slower, not rarer.
//
// A resample node never has to outlive the depth it belongs to. Drawing a pool
// DEPTH-MAJOR -- every ordinal at depth 1, then every ordinal at depth 2 --
// consumes each depth's node exactly once, in ordinal order, which is the same
// sequence the node sees in the game. So the node can be taken, used and handed
// straight back, and the cache stays at a handful of entries where every lookup
// hits the lastNode fast path.
//
// Exactness rests on the same argument the deep_negative_shops staging uses:
// each rng node is an independent stream keyed by its own name, so only the
// order of draws WITHIN a node can matter, and that order is unchanged.
// ---------------------------------------------------------------------------
#define ANN_MASK_WORDS ((ANN_MAX_CARDS + 63) / 64)
typedef struct AnnMask { ulong w[ANN_MASK_WORDS]; } ann_mask;
inline void annm_clear(ann_mask* m) { for (int i = 0; i < ANN_MASK_WORDS; i++) m->w[i] = 0UL; }
inline void annm_set(ann_mask* m, int o) { m->w[o >> 6] |= 1UL << (o & 63); }
inline bool annm_get(const ann_mask* m, int o) { return ((m->w[o >> 6] >> (o & 63)) & 1UL) != 0UL; }
inline bool annm_any(const ann_mask* m) {
    ulong any = 0UL;
    for (int i = 0; i < ANN_MASK_WORDS; i++) any |= m->w[i];
    return any != 0UL;
}

// How many of a pool's items are still unlocked. A pool with none left cannot
// be drawn from at all: the resample loop -- the game's and ours -- looks for an
// unlocked item and never finds one.
inline int ann_pool_open(instance* inst, __constant item items[]) {
    int n = 0;
    for (int i = 1; i <= (int)items[0]; i++) if (!i_locked(inst, items[i])) n++;
    return n;
}

// What a draw yields when its pool has nothing unlocked left. The plain Joker
// is Common, scores nothing, and is never a pool this filter locks, so it
// cannot feed back into the engine.
#define ANN_POOL_EMPTY Joker

// randchoice_common that cannot spin.
//
// The cola engine keeps every negative Uncommon, so the Uncommon pool drains to
// the one item that is never kept -- Diet Cola, which is always sold. A Buffoon
// pack then locks each joker it draws so the pack cannot show the same one
// twice, and if it draws that last Diet Cola the pool is EMPTY: a later
// Uncommon card in the same pack enters the resample loop looking for an
// unlocked item that no longer exists, and never leaves. The game cannot reach
// this (you cannot own 43 Uncommons), so there is no right answer to copy --
// only a deterministic one. The base draw is still consumed, exactly as it
// would be; only the resamples that could never terminate are skipped.
item ann_choice_guarded(instance* inst, rtype rngType, rsrc src, int ante, __constant item items[]) {
    item i = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante},
                        (__private int[]){rngType, src, ante}, 3, items);
    if (!inst->params.showman && i_locked(inst, i)) {
        if (ann_pool_open(inst, items) == 0) return ANN_POOL_EMPTY;
        int resampleNum = 1;
        while (i_locked(inst, i)) {
            i = randchoice(inst, (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample},
                           (__private int[]){rngType, src, ante, resampleNum}, 4, items);
            resampleNum++;
        }
    }
    return i;
}

// Take a node's state and give the slot straight back. Resolving the same node
// later recomputes the identical initial state from the seed, which is exactly
// what a refinement re-pass wants: the stream restarts from the beginning.
inline double ann_take_node(instance* inst, ntype nts[], int ids[], int num) {
    int before = inst->rngCache.nextFreeNode;
    rng_node_id nd = rng_node_resolve(inst, nts, ids, num);
    double st = inst->rngCache.nodes[nd].rngState;
    if (nd == before && inst->rngCache.nextFreeNode == before + 1) {
        inst->rngCache.nextFreeNode = before;   // freshly appended; hand it back
        inst->rngCache.lastNode = -1;
    }
    return st;
}

// ---------------------------------------------------------------------------
// THE BRANCH-INVARIANT SHOP SKELETON
//
// Which shop cards are Jokers, each Joker's rarity and each Joker's edition come
// off three ante-keyed nodes -- R_Card_Type, R_Joker_Rarity/S_Shop and
// R_Joker_Edition/S_Shop -- in loops whose length depends only on the ante and
// on Overstock. None of the three consults the lock set. Locking a joker
// changes which identity a draw RESOLVES to; it cannot move the card-type,
// rarity or edition streams themselves, and the voucher sequence that sets
// frameSize is drawn against voucher locks only, which no branch touches.
//
// So a given ante has ONE skeleton, shared by every branch of the tree, and the
// search can compute it once instead of tens of millions of times. Checked
// rather than assumed: -D ANN_INVARIANCE_CHECK walks every ante twice from the
// same state, the second time with 20 extra Uncommons locked, and reports
// whether the skeletons agree (they do, in all 36 antes, while ~2000 joker
// identities differ).
//
// A cache keyed by ante is enough, and it is never invalidated: the DFS path
// from the root to any node touches each ante at most once, and backtracking
// cannot dirty an entry that did not depend on the branch in the first place.
// So each ante is drawn on its first visit and read back on the other ~44
// million.
//
// It is stored PACKED -- one bit per card for "is a Joker", two bits per Joker
// for rarity and two for edition -- because the unpacked form is five shorts
// per card, and 36 antes of that is 130 KB. Packed it is 13 KB. Unpacking is
// integer work weighed against 924 fp64 draws, so the trade is not close.
//
// Measured: removing the skeleton draws entirely is worth 34% to 41% of the
// per-ante-walk cost (per-walk 1.960 -> 1.151 ms at ANN_LAST_ANTE=24, 2.344 ->
// 1.552 ms at 26).
//
// -D ANN_NO_SKELETON_CACHE compiles it out, which is how the cached and
// uncached searches are checked against each other.
// ---------------------------------------------------------------------------
#define ANN_SKEL_JWORDS(cards) (((cards) + 63) / 64)
#define ANN_SKEL_RWORDS(cards) ((2 * (cards) + 63) / 64)
// ANN_ETERNAL_ONLY adds one bit per Joker for the Eternal sticker, after the
// edition words. The sticker poll is ante-keyed and never looks at the lock
// set either, so it is as branch-invariant as the rest of the skeleton.
#ifdef ANN_ETERNAL_ONLY
#define ANN_SKEL_ULONGS(cards) (2 * ANN_SKEL_JWORDS(cards) + 2 * ANN_SKEL_RWORDS(cards))
#else
#define ANN_SKEL_ULONGS(cards) (ANN_SKEL_JWORDS(cards) + 2 * ANN_SKEL_RWORDS(cards))
#endif

// Big enough for antes 3-38 reserved at the worst-case frame size (12.8 KB).
// Antes that do not fit are simply not cached -- they redraw, exactly as
// before -- so raising ANN_LAST_ANTE without raising this costs speed, never
// correctness. The Eternal bits take antes 3-38 to 2028 words.
#ifndef ANN_SKEL_WORDS
#ifdef ANN_ETERNAL_ONLY
#define ANN_SKEL_WORDS 2048
#else
#define ANN_SKEL_WORDS 1664
#endif
#endif

typedef struct AnnSkel {
    ulong w[ANN_SKEL_WORDS];
    int   off[ANN_LAST_ANTE + 2];    // word offset of this ante's slot, or -1
    short jc[ANN_LAST_ANTE + 2];
    uchar filled[ANN_LAST_ANTE + 2];
} ann_skel;

// Reserve every ante a slot up front, sized at frameSize 4 so the reservation
// does not have to know what the vouchers will do. Walk the antes BACKWARDS:
// if the arena cannot hold them all, the ones that miss out are the early antes
// the search visits a handful of times, not the deep ones it spends all of its
// time in.
void ann_skel_init(ann_skel* sk) {
    for (int ante = 0; ante <= ANN_LAST_ANTE + 1; ante++) {
        sk->off[ante] = -1;
        sk->jc[ante] = 0;
        sk->filled[ante] = 0;
    }
#ifndef ANN_NO_SKELETON_CACHE
    int bump = 0;
    for (int ante = ANN_LAST_ANTE; ante >= ANN_FIRST_ANTE; ante--) {
        int need = ANN_SKEL_ULONGS(ann_frames(ante) * 4);
        if (bump + need > ANN_SKEL_WORDS) continue;
        sk->off[ante] = bump;
        bump += need;
    }
#endif
}

// A joker kept at a given ordinal. It leaves the pool for every LATER ordinal
// and no earlier one, so a pass has to switch each lock on as it sweeps past
// that ordinal rather than holding them all from the start.
typedef struct AnnKeep { short ord; short id; } ann_keep;

inline void ann_keeps_off(instance* inst, const ann_keep* keeps, int n) {
    for (int i = 0; i < n; i++) i_unlock(inst, (item)keeps[i].id);
}
inline void ann_keeps_on(instance* inst, const ann_keep* keeps, int n) {
    for (int i = 0; i < n; i++) i_lock(inst, (item)keeps[i].id);
}

// One depth-major pass over `n` ordinals of a single pool, writing each
// ordinal's resolved item to out[]. `keeps` must be sorted by ordinal; each one
// is locked as the sweep passes its ordinal, so a keep discovered at ordinal k
// affects ordinals after k and leaves everything before k alone -- which is what
// makes lock-as-soon-as-seen exact rather than approximate.
//
// `open`, when given, marks the ordinals drawn with Showman held: Blueprint and
// Brainstorm are unlocked there and locked everywhere else, and left locked
// afterwards (Rare pool only).
inline void ann_copy_state(instance* inst, const ann_mask* open, int o) {
    if (open == 0) return;
    if (annm_get(open, o)) { i_unlock(inst, Blueprint); i_unlock(inst, Brainstorm); }
    else                   { i_lock(inst, Blueprint);   i_lock(inst, Brainstorm); }
}

void ann_flush_pool(instance* inst, ann_ctx* c, rtype rngType, rsrc src, int ante,
                    __constant item items[], int n, short* out,
                    const ann_keep* keeps, int keepCount, const ann_mask* open) {
    if (n <= 0) return;
    int itemCount = (int)items[0];
    lrandom rng = inst->rng;
    ann_mask pending;
    annm_clear(&pending);

    double st = ann_take_node(inst,
        (__private ntype[]){N_Type, N_Source, N_Ante},
        (__private int[]){rngType, src, ante}, 3);
    ann_keeps_off(inst, keeps, keepCount);
    int kp = 0;
    for (int o = 0; o < n; o++) {
        while (kp < keepCount && keeps[kp].ord < o) { i_lock(inst, (item)keeps[kp].id); kp++; }
        rng = randomseed(ann_advance(inst, &st));
        item it = items[l_randint(&rng, 1, itemCount)];
        out[o] = (short)it;
#ifdef ANN_PROFILE
        c->draws++;
#endif
        ann_copy_state(inst, open, o);
        if (!inst->params.showman && i_locked(inst, it)) annm_set(&pending, o);
    }
    if (open != 0) { i_lock(inst, Blueprint); i_lock(inst, Brainstorm); }

    // Nothing unlocked means no resample can ever terminate. Checked with every
    // keep applied, which is the most-locked the sweep below ever gets, so one
    // check covers the whole loop. The shop takes no temporary locks, so unlike
    // the packs this should never fire; it is here so an exhausted pool can
    // never become a hang.
    if (ann_pool_open(inst, items) == 0) {
        for (int o = 0; o < n; o++) if (annm_get(&pending, o)) out[o] = (short)ANN_POOL_EMPTY;
        ann_keeps_on(inst, keeps, keepCount);
        inst->rng = rng;
        return;
    }
    for (int depth = 1; annm_any(&pending); depth++) {
#ifdef ANN_PROFILE
        c->depths++;
#endif
        double rs = ann_take_node(inst,
            (__private ntype[]){N_Type, N_Source, N_Ante, N_Resample},
            (__private int[]){rngType, src, ante, depth}, 4);
        ann_keeps_off(inst, keeps, keepCount);
        kp = 0;
        ann_mask next;
        annm_clear(&next);
        // Set bits in increasing ordinal order: low word first, low bit first.
        for (int word = 0; word < ANN_MASK_WORDS; word++) {
            ulong m = pending.w[word];
            int off = word * 64;
            while (m != 0UL) {
                ulong low = m & (~m + 1UL);
                int o = off + (int)(63UL - clz(low));
                m ^= low;
                while (kp < keepCount && keeps[kp].ord < o) { i_lock(inst, (item)keeps[kp].id); kp++; }
                rng = randomseed(ann_advance(inst, &rs));
                item it = items[l_randint(&rng, 1, itemCount)];
                out[o] = (short)it;
#ifdef ANN_PROFILE
                c->draws++;
#endif
                ann_copy_state(inst, open, o);
                if (i_locked(inst, it)) annm_set(&next, o);
            }
        }
        pending = next;
    }
    if (open != 0) { i_lock(inst, Blueprint); i_lock(inst, Brainstorm); }
    ann_keeps_on(inst, keeps, keepCount);
    inst->rng = rng;
}

#define ANN_R_COMMON   0
#define ANN_R_UNCOMMON 1
#define ANN_R_RARE     2

#define ANN_ED_NEGATIVE 1
#define ANN_ED_ANY      2
// Not an edition: the Eternal sticker, carried in the same per-joker byte. Only
// ever set under ANN_ETERNAL_ONLY, and packed into the skeleton separately.
#define ANN_ED_ETERNAL  4

// Whether a Negative joker with these stickers can count towards the score.
inline bool ann_counts(bool eternal) {
#ifdef ANN_ETERNAL_ONLY
    return eternal;
#else
    (void)eternal;
    return true;
#endif
}

#define ANN_NONE    0
#define ANN_T1_COPY 1
#define ANN_T1_UNC  2
#define ANN_T2      3

inline long ann_score(const ann_ctx* c) {
    return (long)c->copies * ANN_W_COPY + (long)c->fives * ANN_W_FIVE + (long)c->ones * ANN_W_ONE;
}

// Everything that distinguishes two branches at an ante boundary. No RNG state
// appears here: every reachable node is ante-keyed and the cache is reset at the
// top of each ante, so re-entering an ante from a snapshot redraws it exactly.
typedef struct AnnSnap {
    ulong locked[LOCKED_WORDS];
    bool vouchers[32];
    ann_ctx ctx;
} ann_snap;

inline void ann_save(const instance* inst, const ann_ctx* c, ann_snap* s) {
    for (int i = 0; i < LOCKED_WORDS; i++) s->locked[i] = inst->locked[i];
    for (int i = 0; i < 32; i++) s->vouchers[i] = inst->params.vouchers[i];
    s->ctx = *c;
}
inline void ann_restore(instance* inst, ann_ctx* c, const ann_snap* s) {
    for (int i = 0; i < LOCKED_WORDS; i++) inst->locked[i] = s->locked[i];
    for (int i = 0; i < 32; i++) inst->params.vouchers[i] = s->vouchers[i];
#ifdef ANN_NODE_PEAK
    int peak = c->nodePeak;
#endif
#ifdef ANN_PROFILE
    long pd = c->draws, pp = c->depths, ps = c->passes, pa = c->antes;
#endif
#ifdef ANN_DOM_AUDIT
    long a1 = c->audPrune, a2 = c->audPruneSameLock, a3 = c->audT1NoFit,
         a4 = c->audT1NoFitWide, a5 = c->audUncGateWide;
#endif
    *c = s->ctx;
#ifdef ANN_DOM_AUDIT
    c->audPrune = a1; c->audPruneSameLock = a2; c->audT1NoFit = a3;
    c->audT1NoFitWide = a4; c->audUncGateWide = a5;
#endif
#ifdef ANN_NODE_PEAK
    c->nodePeak = peak;   // a high-water mark, not branch state
#endif
#ifdef ANN_PROFILE
    c->draws = pd; c->depths = pp; c->passes = ps; c->antes = pa;
#endif
}

// One ante's shop jokers, in queue order. Held so a window can be chosen from a
// scouting walk and then committed on a re-walk of the same ante.
typedef struct AnnAnte {
    int jokerCards;
    int halfCards;      // first-half boundary, in cards
    int frameSize;
    short cardIdx[ANN_MAX_CARDS];
    uchar rar[ANN_MAX_CARDS];
    uchar ed[ANN_MAX_CARDS];
    short ident[ANN_MAX_CARDS];
    short elig[ANN_MAX_CARDS];      // per joker slot: eligible-target ordinal, or -1
    short eligSlot[ANN_MAX_CARDS];  // per eligible ordinal: the joker slot
    short poolSlot[ANN_MAX_CARDS];  // scratch: pool ordinal -> joker slot
    short poolOut[ANN_MAX_CARDS];   // scratch: pool ordinal -> drawn item
    short pick[ANN_MAX_CARDS];      // per Rare slot: its identity with Showman held
    int eligCount;
} ann_ante;


// A Negative Tag window: `width` consecutive eligible shop jokers starting at
// eligible-target ordinal `start`, all of which must sit before `limitCards`.
// `log` says where this window's score is reported. For a first-slot window
// that is the ante's own log; for a second-slot window it is the log of the
// EARLIER ante whose tag created it, so the points land against the tag that
// paid for them rather than the ante they happen to land in.
typedef struct AnnWin { int start, width, limitCards; ann_log* log; } ann_win;

// At most one keep per Uncommon in the pool, and a kept one never comes back.
#define ANN_MAX_KEEPS 80

// Is this shop joker inside a Negative Tag window? elig is -1 for a joker that
// already has an edition, and window starts are never negative, so those never
// match.
inline int ann_target_window(const ann_ante* a, int slot, const ann_win* wins, int nwins) {
    for (int w = 0; w < nwins; w++)
        if (a->elig[slot] >= wins[w].start && a->elig[slot] < wins[w].start + wins[w].width)
            return w;
    return -1;
}
inline bool ann_is_target(const ann_ante* a, int slot, const ann_win* wins, int nwins) {
    return ann_target_window(a, slot, wins, nwins) >= 0;
}

// Uncommons that are never bought, even Negative. They score nothing, they are
// never kept -- so they stay in the pool and cannot shrink it for Diet Cola --
// and a Negative Tag window does not count them towards its Uncommon total: a
// window that spends its negatives on these has bought nothing.
//
// Burglar is the exception. From ANN_BURGLAR_FROM_ANTE it is worth a slot and
// is kept like any other Uncommon; it still scores nothing, it just shrinks the
// pool from that ante on.
#ifndef ANN_BURGLAR_FROM_ANTE
#define ANN_BURGLAR_FROM_ANTE 35
#endif
inline bool ann_never_buy(item joker, int ante) {
    if (joker == Madness || joker == Showman) return true;
    if (joker == Burglar) return ante < ANN_BURGLAR_FROM_ANTE;
    return false;
}

// Whether a Negative Uncommon is bought and kept, shrinking the pool. Under
// ANN_ETERNAL_ONLY an Eternal one is passed over -- it could never be sold
// again -- except Mime, which is a target and is bought only WITH the sticker
// in mind. (Diet Cola never reaches here, and cannot be Eternal anyway: the
// game gives it no sticker, see the eternal_compat list in lib/functions.cl.)
inline bool ann_buys_uncommon(item joker, int ante, bool eternal) {
    if (ann_never_buy(joker, ante)) return false;
#ifdef ANN_ETERNAL_ONLY
    if (eternal) return joker == Mime;
#else
    (void)eternal;
#endif
    return true;
}

// Points a single joker is worth once it is Negative.
inline int ann_value(item joker, bool* isCopy) {
    *isCopy = (joker == Blueprint || joker == Brainstorm);
    if (*isCopy) return ANN_W_COPY;
#ifdef ANN_ETERNAL_ONLY
    if (joker == Baron || joker == Mime) return ANN_W_FIVE;
#else
    if (joker == Baron || joker == DNA || joker == Mime) return ANN_W_FIVE;
#endif
#ifdef ANN_SCORE_COMMONS
    if (joker == Juggler || joker == Drunkard) return ANN_W_ONE;
#endif
    return 0;
}

// Farming Diet Colas off copy jokers.
//
// A held Diet Cola is copied by a copy joker, which therefore also carries
// "sell this card to create a free Double Tag". Selling the copy joker you have
// and buying the next one nets a Double Tag each time, so every non-Negative
// copy joker met after the first Diet Cola is worth one more cola. Editions do
// not matter -- a Foil Blueprint sells just as well.
//
// It stops per kind once a Negative one of that kind turns up: that one is kept
// rather than sold. So a negative Blueprint leaves Brainstorm still farming, and
// only both together shut it off.
//
// Under ANN_ETERNAL_ONLY the sticker decides instead: an Eternal copy joker
// cannot be sold, so a non-Negative one is never bought and farms nothing, and
// only a Negative Eternal one is kept. A Negative one without the sticker
// scores nothing, so it is sold like the rest.
inline void ann_saw_copy(ann_ctx* c, item joker, bool negative, bool eternal) {
    bool bp = (joker == Blueprint);
#ifdef ANN_ETERNAL_ONLY
    if (eternal && !negative) {
#ifdef ANN_EXPLAIN
        c->skipEternal++;
#endif
        return;
    }
    bool soldNegative = negative && !eternal;
    negative = negative && eternal;
#else
    (void)eternal;
    bool soldNegative = false;
#endif
    (void)soldNegative;
    if (negative) {
        if (bp) c->negBlueprint = true; else c->negBrainstorm = true;
        return;
    }
    if (c->seenCola && !(bp ? c->negBlueprint : c->negBrainstorm)) {
        c->colas++;
#ifdef ANN_EXPLAIN
        if (soldNegative) c->srcFarmNeg++; else c->srcFarm++;
#endif
    }
#ifdef ANN_EXPLAIN
    else if (!c->seenCola) c->noTemplate++;
    else c->noFarm++;
#endif
}

// Colas are worth ~90% of the count when actually cashed in: one is held as the
// farming template, and a real run is not perfectly efficient. Applied only
// where a tag spends them, never to the stock itself -- banking is a line the
// search is meant to weigh, and taxing it per branch point would quietly bias
// against it.
#ifndef ANN_COLA_EFFICIENCY_NUM
#define ANN_COLA_EFFICIENCY_NUM 9
#endif
#ifndef ANN_COLA_EFFICIENCY_DEN
#define ANN_COLA_EFFICIENCY_DEN 10
#endif
inline int ann_colas_effective(int colas) {
    return (int)(((long)colas * ANN_COLA_EFFICIENCY_NUM) / ANN_COLA_EFFICIENCY_DEN);
}

// Keeping a negative Uncommon takes it out of the pool. Never take the last
// few if a floor is set: a pool drawn down to nothing is what makes the
// resample chains, and the node budget, run away.
inline void ann_keep_uncommon(instance* inst, ann_ctx* c, item joker) {
    if (c->uncAvail <= ANN_LOCK_FLOOR) return;
    i_lock(inst, joker);
    c->uncAvail--;
}

inline void ann_credit(ann_ctx* c, int value, bool isCopy) {
    if (isCopy) c->copies++;
    else if (value == ANN_W_FIVE) c->fives++;
    else if (value == ANN_W_ONE) c->ones++;
}


// ---------------------------------------------------------------------------
// One ante. Called twice per branch that spends a tag: once with no window, to
// draw the queue and choose a start from it, and once more from the same
// snapshot with the window committed. The second call is the one that counts --
// its locks shift the stream, so the scouted identities past the window start
// are only a guess and the committed walk is what gets scored.
// ---------------------------------------------------------------------------
void ann_ante_walk(instance* inst, ann_ctx* c, ann_ante* a, int ante,
                   shop sh, double totalRate,
                   const ann_win* wins, int nwins,
                   int* colasAfterPacks, bool spendColas, bool scout,
                   ann_skel* sk, ann_log* log) {
    // Every reachable node is ante-keyed, so last ante's slots are unreachable.
    inst->rngCache.nextFreeNode = 0;
    inst->rngCache.lastNode = -1;

    item v = next_voucher(inst, ante);
    for (int i = 0; i < (int)(sizeof(ANN_BOUGHT_VOUCHERS) / sizeof(item)); i++) {
        if (ANN_BOUGHT_VOUCHERS[i] == v) { activate_voucher(inst, v); break; }
    }
    if (v == Overstock) c->overstock = true;
    if (v == Overstock_Plus) c->overstockPlus = true;
    a->jokerCards = 0;
    a->eligCount = 0;
    if (ante < ANN_FIRST_ANTE) { *colasAfterPacks = c->colas; return; }

    // -- Buffoon packs first, so their Diet Colas are banked before the shop --
    for (int p = 0; p < ANN_PACKS; p++) {
        pack _pack = pack_info(next_pack(inst, ante));
        if (_pack.type != Buffoon_Pack) continue;
        item drawn[5];
        rarity rr[5];
        for (int j = 0; j < _pack.size; j++) {
            rarity r = next_joker_rarity(inst, S_Buffoon, ante);
            item joker;
            if (r == Rarity_Rare)          joker = ann_choice_guarded(inst, R_Joker_Rare, S_Buffoon, ante, RARE_JOKERS);
            else if (r == Rarity_Uncommon) joker = ann_choice_guarded(inst, R_Joker_Uncommon, S_Buffoon, ante, UNCOMMON_JOKERS);
            else                           joker = ann_choice_guarded(inst, R_Joker_Common, S_Buffoon, ante, COMMON_JOKERS);
            rr[j] = r;
            drawn[j] = joker;
            if (!inst->params.showman) i_lock(inst, joker); // temporary, as buffoon_pack does
        }
        for (int j = 0; j < _pack.size; j++) i_unlock(inst, drawn[j]);
        // Editions and scoring only after the temporary locks are lifted, so a
        // permanent lock taken here is not undone by the loop above.
        for (int j = 0; j < _pack.size; j++) {
            bool negative = next_joker_edition(inst, S_Buffoon, ante) == Negative;
#ifdef ANN_ETERNAL_ONLY
            // One sticker poll per pack joker, drawn for every card whatever
            // it turns out to be, as create_card does.
            bool eternal = random(inst, (__private ntype[]){N_Type, N_Ante},
                                  (__private int[]){R_Eternal_Perishable_Pack, ante}, 2) > 0.7;
#else
            bool eternal = false;
#endif
            if (drawn[j] == Diet_Cola) {
                c->colas++;
                c->seenCola = true;
#ifdef ANN_EXPLAIN
                c->srcPack++;
#endif
                continue;
            }
            if (drawn[j] == Blueprint || drawn[j] == Brainstorm)
                ann_saw_copy(c, drawn[j], negative, eternal);
            if (!negative) continue;
            bool isCopy;
            // Scores only with the sticker under ANN_ETERNAL_ONLY. The keep
            // below is separate: see ann_buys_uncommon.
            if (ann_counts(eternal)) ann_credit(c, ann_value(drawn[j], &isCopy), isCopy);
            // Kept, so it leaves the Uncommon pool. Pack jokers are never
            // Negative Tag targets -- the tag only reads the shop queue.
            // ANN_POOL_EMPTY is Common, so it never enters the Uncommon pool
            // accounting even when an Uncommon slot fell back to it.
            if (rr[j] == Rarity_Uncommon && drawn[j] != ANN_POOL_EMPTY
                && ann_buys_uncommon(drawn[j], ante, eternal))
                ann_keep_uncommon(inst, c, drawn[j]);
        }
    }

#ifdef ANN_PROFILE
    c->antes++;
#endif
    // A first-slot Negative Tag is chained through every banked Double Tag the
    // moment it is taken, which is before this ante's shop: the colas are spent
    // and the count restarts from zero for later antes.
    *colasAfterPacks = c->colas;
    if (spendColas) c->colas = 0;

    // -- shop queue --
    int frameSize = 2;
    if (c->overstock || ante >= 12) frameSize = 3;
    if (c->overstockPlus || ante >= 24) frameSize = 4;
    int cards = ann_frames(ante) * frameSize;
    a->frameSize = frameSize;
    a->halfCards = cards / 2;

    // ---- skeleton: joker positions, rarities, editions ----
    // Branch-invariant, so drawn once per ante and read back afterwards. See
    // the ann_skel block above for why that is exact.
    lrandom scratch;
    int jc = 0;
    int base = (sk != 0 && ante <= ANN_LAST_ANTE) ? sk->off[ante] : -1;
    int jw = ANN_SKEL_JWORDS(cards);
    int rw = ANN_SKEL_RWORDS(cards);

    if (base >= 0 && sk->filled[ante]) {
        jc = (int)sk->jc[ante];
        // Set bits in increasing card order: low word first, low bit first,
        // the same scan ann_flush_pool uses.
        int o = 0;
        for (int word = 0; word < jw; word++) {
            ulong m = sk->w[base + word];
            int off = word * 64;
            while (m != 0UL) {
                ulong low = m & (~m + 1UL);
                a->cardIdx[o++] = (short)(off + (int)(63UL - clz(low)));
                m ^= low;
            }
        }
        for (int j = 0; j < jc; j++) {
            int rb = 2 * j;   // always even, so a 2-bit field never straddles a word
            a->rar[j] = (uchar)((sk->w[base + jw + (rb >> 6)] >> (rb & 63)) & 3UL);
            a->ed[j]  = (uchar)((sk->w[base + jw + rw + (rb >> 6)] >> (rb & 63)) & 3UL);
#ifdef ANN_ETERNAL_ONLY
            if ((sk->w[base + jw + 2 * rw + (j >> 6)] >> (j & 63)) & 1UL) a->ed[j] |= ANN_ED_ETERNAL;
#endif
        }
    } else {
        if (base >= 0) for (int k = 0; k < ANN_SKEL_ULONGS(cards); k++) sk->w[base + k] = 0UL;

        rng_node_id ctNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2);
        double ctState = inst->rngCache.nodes[ctNode].rngState;
        for (int i = 0; i < cards; i++) {
            double cardType = ann_random(inst, &ctState, &scratch) * totalRate;
            if (get_item_type(sh, cardType) == ItemType_Joker) {
                a->cardIdx[jc++] = (short)i;
                if (base >= 0) sk->w[base + (i >> 6)] |= 1UL << (i & 63);
            }
        }
        inst->rngCache.nodes[ctNode].rngState = ctState;

        rng_node_id rarNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, ante, S_Shop}, 3);
        rng_node_id edNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Edition, S_Shop, ante}, 3);
        double rarState = inst->rngCache.nodes[rarNode].rngState;
        double edState = inst->rngCache.nodes[edNode].rngState;
        for (int j = 0; j < jc; j++) {
            double rp = ann_random(inst, &rarState, &scratch);
            uchar r = rp > 0.95 ? ANN_R_RARE : (rp > 0.7 ? ANN_R_UNCOMMON : ANN_R_COMMON);
            // One poll decides the whole edition: Negative above 0.997, and any
            // edition at all above 0.96. Anything with an edition is passed over by
            // a Negative Tag without consuming it.
            double ep = ann_random(inst, &edState, &scratch);
            uchar e = 0;
            if (ep > 0.997) e |= ANN_ED_NEGATIVE;
            if (ep > 0.96) e |= ANN_ED_ANY;
            a->rar[j] = r;
            a->ed[j] = e;
            if (base >= 0) {
                int rb = 2 * j;
                sk->w[base + jw + (rb >> 6)]      |= (ulong)r << (rb & 63);
                sk->w[base + jw + rw + (rb >> 6)] |= (ulong)e << (rb & 63);
            }
        }
        inst->rngCache.nodes[rarNode].rngState = rarState;
        inst->rngCache.nodes[edNode].rngState = edState;

#ifdef ANN_ETERNAL_ONLY
        // One sticker poll per shop joker in queue order, whatever its
        // identity. Above 0.7 is Eternal; every scored target is compatible.
        rng_node_id etNode = rng_node_resolve(inst,
            (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Eternal_Perishable, ante}, 2);
        double etState = inst->rngCache.nodes[etNode].rngState;
        for (int j = 0; j < jc; j++) {
            if (ann_random(inst, &etState, &scratch) <= 0.7) continue;
            a->ed[j] |= ANN_ED_ETERNAL;
            if (base >= 0) sk->w[base + jw + 2 * rw + (j >> 6)] |= 1UL << (j & 63);
        }
        inst->rngCache.nodes[etNode].rngState = etState;
#endif

        if (base >= 0) { sk->jc[ante] = (short)jc; sk->filled[ante] = 1; }
    }

    a->jokerCards = jc;
    if (jc == 0) return;

    // Eligible-target numbering is derived from the skeleton, not drawn, so it
    // is recomputed on both paths rather than being cached with it.
    int eligCount = 0;
    for (int j = 0; j < jc; j++) {
        a->ident[j] = 0;
        if (a->ed[j] & ANN_ED_ANY) {
            a->elig[j] = -1;
        } else {
            a->elig[j] = (short)eligCount;
            a->eligSlot[eligCount] = (short)j;
            eligCount++;
        }
    }
    a->eligCount = eligCount;

    // ---- identities, pool by pool ----
    // Nothing below consumes a cache node: each pool is drawn depth-major and
    // every node is handed back (see ann_flush_pool).
    int n;

    n = 0;
    for (int j = 0; j < jc; j++) if (a->rar[j] == ANN_R_RARE) a->poolSlot[n++] = (short)j;
    {
        // Showman is held from each window's first card to its last, so the
        // copy jokers are open on exactly the Rare ordinals in those spans.
        ann_mask open;
        annm_clear(&open);
        for (int w = 0; w < nwins; w++) {
            int s = wins[w].start;
            int e = wins[w].start + wins[w].width;
            if (e > eligCount) e = eligCount;
            if (s >= e) continue;
            int lo = a->cardIdx[a->eligSlot[s]];
            int hi = a->cardIdx[a->eligSlot[e - 1]];
            for (int o = 0; o < n; o++) {
                int card = a->cardIdx[a->poolSlot[o]];
                if (card >= lo && card <= hi) annm_set(&open, o);
            }
        }
        ann_flush_pool(inst, c, R_Joker_Rare, S_Shop, ante, RARE_JOKERS, n, a->poolOut,
                       (const ann_keep*)0, 0, &open);
        for (int o = 0; o < n; o++) a->ident[a->poolSlot[o]] = a->poolOut[o];
        if (scout) {
            // Where a copy joker WOULD show up with Showman held all ante, for
            // choosing a first-slot window. Same nodes, redrawn from the start.
            for (int o = 0; o < n; o++) annm_set(&open, o);
            ann_flush_pool(inst, c, R_Joker_Rare, S_Shop, ante, RARE_JOKERS, n, a->poolOut,
                           (const ann_keep*)0, 0, &open);
            for (int o = 0; o < n; o++) a->pick[a->poolSlot[o]] = a->poolOut[o];
        }
    }

#ifdef ANN_SCORE_COMMONS
    // The Common identity node and its resample chain are read by nothing else
    // and are discarded at the ante boundary, so the stream can stop after the
    // last Common whose identity can still change the score. Exact.
    n = 0;
    int lastCommon = 0;
    for (int j = 0; j < jc; j++) {
        if (a->rar[j] != ANN_R_COMMON) continue;
        a->poolSlot[n++] = (short)j;
        if ((a->ed[j] & ANN_ED_NEGATIVE) || ann_is_target(a, j, wins, nwins)) lastCommon = n;
    }
    ann_flush_pool(inst, c, R_Joker_Common, S_Shop, ante, COMMON_JOKERS, lastCommon, a->poolOut,
                   (const ann_keep*)0, 0, (const ann_mask*)0);
    for (int o = 0; o < lastCommon; o++) a->ident[a->poolSlot[o]] = a->poolOut[o];
#endif

    // Uncommons, with lock-as-soon-as-seen. A kept Uncommon leaves the pool for
    // every later ordinal, which shifts their draws, so the pass is redone from
    // the first ordinal that keeps one. Each pass finalises one more prefix, so
    // this converges in (keeps + 1) passes -- and because ann_flush_pool
    // switches each keep on only as it sweeps past that ordinal, the ordinals
    // before it are redrawn exactly as they were.
    ann_keep keeps[ANN_MAX_KEEPS];
    int keepCount = 0;
    n = 0;
    for (int j = 0; j < jc; j++) if (a->rar[j] == ANN_R_UNCOMMON) a->poolSlot[n++] = (short)j;
    int finalized = 0;
    while (true) {
        ann_flush_pool(inst, c, R_Joker_Uncommon, S_Shop, ante, UNCOMMON_JOKERS, n, a->poolOut,
                       keeps, keepCount, (const ann_mask*)0);
#ifdef ANN_PROFILE
        c->passes++;
#endif
        // Accept as many keeps from this pass as stay trustworthy. Locking an
        // item only perturbs a later ordinal if that ordinal DREW it: a chain
        // terminates on the first unlocked item it hits, so an item that was
        // unlocked during this pass can only appear as a final identity, never
        // as a link in someone else's chain. So the pass stays valid right up
        // to the first ordinal that drew something we just locked -- that one
        // would now resample, which shifts every draw after it too.
        short newly[ANN_MAX_KEEPS];
        int added = 0;
        int o = finalized;
        for (; o < n; o++) {
            item id = (item)a->poolOut[o];
            bool perturbed = false;
            for (int i = 0; i < added; i++) if (newly[i] == (short)id) { perturbed = true; break; }
            if (perturbed) break;   // trust horizon
            if (id == Diet_Cola) continue;         // always sold, so never kept
            if (id == ANN_POOL_EMPTY) continue;    // exhausted-pool fallback, a Common
            int slot = a->poolSlot[o];
            // never bought, so never kept
            if (!ann_buys_uncommon(id, ante, (a->ed[slot] & ANN_ED_ETERNAL) != 0)) continue;
            if (!((a->ed[slot] & ANN_ED_NEGATIVE) || ann_is_target(a, slot, wins, nwins))) continue;
            if (c->uncAvail <= ANN_LOCK_FLOOR || keepCount >= ANN_MAX_KEEPS) { o = n; break; }
            keeps[keepCount].ord = (short)o;
            keeps[keepCount].id = (short)id;
            keepCount++;
            i_lock(inst, id);
            c->uncAvail--;
            newly[added++] = (short)id;
        }
        finalized = o;
        // Ran the whole pool without hitting the horizon: every identity in
        // this pass is final, whatever was locked along the way.
        if (o >= n) break;
    }
    for (int o = 0; o < n; o++) a->ident[a->poolSlot[o]] = a->poolOut[o];

    // ---- score, in queue order ----
    // At most one Diet Cola per shop frame: the first one is in the shop, so
    // the game's pool excludes it for the rest of that frame's slots. It is
    // sold on sight, so the next frame can draw it again.
    int lastColaFrame = -1;
    for (int j = 0; j < jc; j++) {
        item id = (item)a->ident[j];
        if (id == Diet_Cola) {
            int frame = a->cardIdx[j] / frameSize;
            if (inst->params.showman || frame != lastColaFrame) {
                c->colas++;
                c->seenCola = true;
#ifdef ANN_EXPLAIN
                c->srcShop++;
#endif
                lastColaFrame = frame;
            }
            continue;
        }
        int w = ann_target_window(a, j, wins, nwins);
        // A window target is made Negative by the tag, so it counts as one here.
        bool negative = (a->ed[j] & ANN_ED_NEGATIVE) || w >= 0;
        bool eternal = (a->ed[j] & ANN_ED_ETERNAL) != 0;
        if (id == Blueprint || id == Brainstorm) ann_saw_copy(c, id, negative, eternal);
        if (!negative || !ann_counts(eternal)) continue;

        bool isCopy;
        int value = ann_value(id, &isCopy);
        ann_credit(c, value, isCopy);
        if (w >= 0 && wins[w].log != 0) {
            // Reported against the window that made it Negative, which for a
            // second-slot tag is an earlier ante's log than this one.
            ann_log* wl = wins[w].log;
            wl->points += value;
            if (value > 0 && wl->nitems < ANN_LOG_ITEMS) wl->items[wl->nitems++] = (short)id;
            // Showman is sold on the first frame boundary after the last copy
            // joker the window takes.
            if (isCopy) wl->lastCopyCard = a->cardIdx[j];
        }
    }
#ifdef ANN_NODE_PEAK
    if (inst->rngCache.nextFreeNode > c->nodePeak) c->nodePeak = inst->rngCache.nextFreeNode;
#endif
}

// Where to start a width-wide window. byCopy maximises copy jokers and breaks
// ties on Uncommons; otherwise it maximises Uncommons. Earliest start wins the
// remaining ties. Returns -1 when no window of that width fits before
// limitCards. Read off the scouting walk, so it is a guess about the committed
// stream, not a promise -- the committed walk is what gets scored.
int ann_pick_window(const ann_ante* a, int ante, int width, int limitCards, int minStart,
                    bool byCopy, int* outCopies, int* outUnc) {
    int best = -1, bc = 0, bu = 0;
    for (int ws = minStart; ws + width <= a->eligCount; ws++) {
        // Eligible ordinals run in card order, so once the far end of the
        // window is past the limit it is past it for every later start.
        if (a->cardIdx[a->eligSlot[ws + width - 1]] >= limitCards) break;
        int copies = 0, unc = 0;
        for (int k = 0; k < width; k++) {
            int slot = a->eligSlot[ws + k];
            item id = (item)a->ident[slot];
            if (a->rar[slot] == ANN_R_RARE) id = (item)a->pick[slot];
            if ((id == Blueprint || id == Brainstorm) && ann_counts((a->ed[slot] & ANN_ED_ETERNAL) != 0))
                copies++;
            // Only Uncommons that would actually be bought: the rest leave the
            // pool untouched, which is the entire point of this branch.
            if (a->rar[slot] == ANN_R_UNCOMMON
                && ann_buys_uncommon(id, ante, (a->ed[slot] & ANN_ED_ETERNAL) != 0)) unc++;
        }
        bool better = byCopy ? (copies > bc || (copies == bc && unc > bu))
                             : (unc > bu || (unc == bu && copies > bc));
        if (best < 0 || better) { best = ws; bc = copies; bu = unc; }
    }
    *outCopies = bc;
    *outUnc = bu;
    return best;
}

inline bool ann_offered(uchar tag, int ante, int choice) {
    if (choice == ANN_NONE) return true;
    if (choice == ANN_T1_COPY || choice == ANN_T1_UNC) return (tag & 1) != 0;
    return (tag & 2) != 0 && ante < ANN_LAST_ANTE;   // T2 needs a next ante to fire in
}

// The order the DFS tries an ante's choices in. It cannot change which leaf is
// best -- the search is exhaustive -- but it decides what the incumbent is
// while the rest of the tree is still being explored, and every prune that
// compares against an incumbent is only as good as that incumbent. NONE is the
// line that banks and does nothing, so trying it first sets the loosest
// possible bar; it goes last. Spending a first-slot tag is the likeliest to
// score, so it goes first.
//
// Ties between equal-scoring leaves are broken by this order too, so the line
// PRINTED for a seed can change when this changes, even though the score does
// not.
__constant int ANN_ORDER[4] = { ANN_T1_COPY, ANN_T1_UNC, ANN_T2, ANN_NONE };

// How many of the four an ante actually offers, and the i-th of them in
// ANN_ORDER. A flat combination number indexes the branch tree through these,
// which is what lets the tree be split across work-items, so the two must agree
// with the DFS below on the order.
inline int ann_arity(uchar tag, int ante) {
    int n = 1;                                        // NONE is always offered
    if (tag & 1) n += 2;                              // T1_COPY, T1_UNC
    if ((tag & 2) && ante < ANN_LAST_ANTE) n += 1;    // T2 needs a next ante
    return n;
}
inline int ann_choice_at(uchar tag, int ante, int i) {
    int seen = 0;
    for (int k = 0; k < 4; k++) {
        int ch = ANN_ORDER[k];
        if (!ann_offered(tag, ante, ch)) continue;
        if (seen == i) return ch;
        seen++;
    }
    return ANN_NONE;
}

// Walk one ante inside a branch: fire any window a second-slot tag left
// pending, then take `choice`. Returns false when the choice is not available
// on this seed (no copy joker in reach, or the Uncommon gate refuses), which
// prunes that subtree instead of duplicating a weaker line.
bool ann_ante_step(instance* inst, ann_ctx* c, ann_ante* a, int ante,
                   shop sh, double totalRate, int choice, ann_skel* sk, ann_log* log) {
    ann_snap start;
    ann_save(inst, c, &start);

    ann_win wins[2];
    int nw = 0;
    int colasAfterPacks = 0;

    // A second-slot tag taken last ante fires from the head of this ante's
    // queue. It is known before any choice is made here, so it goes into the
    // first walk rather than being bolted on afterwards -- otherwise a
    // first-slot window in the same ante would be chosen off a stream missing
    // this window's locks.
    ann_log* pendLog = 0;
    if (c->pendingWidth > 0) {
        wins[nw].start = 0;
        wins[nw].width = c->pendingWidth;
        wins[nw].limitCards = 1 << 30;   // a second-slot window has no half limit
        wins[nw].log = c->pendingLog;    // score it against the tag that paid
        pendLog = c->pendingLog;
        nw++;
    }
    c->pendingWidth = 0;
    c->pendingLog = 0;
    // The scouting walk below scores any pending window, and the committed walk
    // scores it again, so its log has to be rewound in between.
    int pendPoints0 = pendLog ? pendLog->points : 0;
    int pendItems0 = pendLog ? pendLog->nitems : 0;
    int pendCopy0 = pendLog ? pendLog->lastCopyCard : -1;

    log->ante = ante;
    log->choice = choice;
    log->width = 0;
    log->startCard = -1;
    log->copies = 0;
    log->uncommons = 0;
    log->nitems = 0;
    log->lastCopyCard = -1;
    log->frameSize = 0;
    log->points = 0;

    // For NONE and T2 this is the whole line. For a first-slot tag it also
    // scouts the queue the window will be chosen from.
    ann_ante_walk(inst, c, a, ante, sh, totalRate, wins, nw, &colasAfterPacks, false,
                  choice == ANN_T1_COPY || choice == ANN_T1_UNC, sk, log);
    log->colas = colasAfterPacks;
    log->frameSize = a->frameSize;

    if (choice == ANN_T1_COPY || choice == ANN_T1_UNC) {
        // Everything inside a pending window is already Negative, so a
        // first-slot window here starts after it.
        int minStart = nw > 0 ? wins[0].start + wins[0].width : 0;
        int width = 1 + ann_colas_effective(colasAfterPacks);

        // How many eligible targets are left in reach at all: eligible ordinals
        // run in card order, so this is just how many sit before halfCards from
        // minStart on.
        //
        // A chained tag used to be REFUSED when the stock was wider than the
        // room left, which made banking more colas strictly worse -- a branch
        // holding more tags lost an option the branch holding fewer kept. The
        // game has no such rule: the tag turns the jokers it reaches Negative
        // and the rest of the chain is simply wasted. So spend what fits and
        // throw the remainder away; the colas are consumed either way.
        int fits = 0;
        for (int e = minStart; e < a->eligCount; e++) {
            if (a->cardIdx[a->eligSlot[e]] >= a->halfCards) break;
            fits++;
        }
        if (fits <= 0) return false;   // nothing in reach: the tag has no target
        if (width > fits) width = fits;

        int copies = 0, unc = 0;
        int ws = ann_pick_window(a, ante, width, a->halfCards, minStart,
                                 choice == ANN_T1_COPY, &copies, &unc);
        if (ws < 0) return false;
        // A copy-joker window holding no copy joker is just a worse NONE.
        if (choice == ANN_T1_COPY && copies < 1) return false;
        // Below half Uncommons the pool barely moves, and past the gate ante
        // there is no run left to spend the extra Diet Colas in.
        // Measured against the width actually spent, not the stock, now that
        // the two can differ.
        if (choice == ANN_T1_UNC && (ante > ANN_UNCOMMON_GATE_ANTE || 2 * unc < width)) {
#ifdef ANN_DOM_AUDIT
            if (2 * unc < width && width > 1) c->audUncGateWide++;
#endif
            return false;
        }
        wins[nw].start = ws;
        wins[nw].width = width;
        wins[nw].limitCards = a->halfCards;
        wins[nw].log = log;   // a first-slot window scores in its own ante
        nw++;

        // Commit: redraw the ante from its own snapshot with the window in
        // place. Its locks shift the stream, so the identities the window was
        // picked on are a guess past its start and only this walk is scored.
        ann_restore(inst, c, &start);
        c->pendingWidth = 0;
        c->pendingLog = 0;
        log->nitems = 0;
        log->lastCopyCard = -1;
        log->points = 0;
        if (pendLog) {   // undo what the scouting walk credited to it
            pendLog->points = pendPoints0;
            pendLog->nitems = pendItems0;
            pendLog->lastCopyCard = pendCopy0;
        }
        ann_ante_walk(inst, c, a, ante, sh, totalRate, wins, nw, &colasAfterPacks, true, false, sk, log);
        log->colas = colasAfterPacks;
        log->width = width;
        log->startCard = a->cardIdx[a->eligSlot[ws]];
        log->copies = copies;
        log->uncommons = unc;
    }

    if (choice == ANN_NONE) log->colas = c->colas;   // what actually got banked
    if (choice == ANN_T2) {
        // Taken now: the banked colas are sold and chained now, and the tag
        // fires in the next ante.
        log->colas = c->colas;   // raw stock; the width below is the 90% of it
        c->pendingWidth = 1 + ann_colas_effective(c->colas);
        c->pendingLog = log;   // its window fires next ante but scores here
        c->colas = 0;
        log->width = c->pendingWidth;
    }
    return true;
}

// ---------------------------------------------------------------------------
// DOMINANCE PRUNING (ON by default; -D ANN_NO_DOMINANCE turns it off)
//
// A branch standing at a branch point behind another branch on every axis that
// matters is dropped. This is a HEURISTIC and it does lose score. What makes it
// worth having by default is WHERE it loses: on mid-pool seeds, never on the
// ranking, which is what a search is actually for.
//
// WHY IT IS NOT SOUND. The axes are a summary, not the state. "ten Uncommons
// left" is a COUNT; the state is WHICH ten. randchoice_common resamples against
// the lock set, so two branches holding different tens draw different jokers at
// the same shop ordinals from there on. Diet Cola is no likelier for either --
// it is never locked, so it is one in N of whatever remains either way -- but
// the realised sequence differs, and a copy joker lands inside one branch's tag
// window and outside the other's. It is a different roll of the same dice, not
// a better one, which is why the damage is symmetric luck rather than bias.
// Audited with -D ANN_DOM_AUDIT over 4,975 seeds at full depth: of 19,643
// prunes, 63.3% had a dominator holding a DIFFERENT lock set.
//
// (There used to be a second reason, and it was worse: refusing a chained tag
// when the cola stock was wider than the room left made MORE colas strictly
// worse, so the axis was not even monotone in the model. ann_ante_step now
// clamps the window to what fits and throws the rest of the chain away, which
// is what the game does. See the `fits` block there.)
//
// WHAT IT COSTS, on 5,000 seeds at full depth:
//   time                          92.8 s -> 34.9 s   (2.66x)
//   seeds scoring lower           75 of 4,975        (1.51%)
//   value kept on those seeds     worst 53.7%, p10 95.2%, median 98.4%
//   pool total                    99.937% kept
//   top-100 seeds by true score   99.96% kept
//   top-10 / top-50 / top-100     the SAME seeds, every one
//   top-250                       249 of 250 the same
// No seed ever scores higher: a pruned branch simply never reaches a leaf.
//
// The seven seeds that keep under 95% sit at the 65th to 75th percentile of the
// pool -- they were never going to be selected. Nothing in the top 2% loses
// more than about a tenth. So for ranking a pool this is close to free, and for
// reporting ONE named seed's exact score it is not: use -D ANN_NO_DOMINANCE
// there.
//
// It cannot be tuned away. ANN_DOM_FRONTIER at 8, 16, 32, 64 and 128 gives
// byte-identical scores, so the loss is not frontier eviction, it is genuine
// domination between states that were never comparable.
//
// -D ANN_DOM_EXACT drops only an exact repeat of a state already seen at that
// depth -- a transposition, which IS lossless (measured: 0 of 5,000 changed).
// It is not a faster option, it is a slower one: exact repeats are rare and the
// lock-bitset compare costs more than they save (84.7 s against 34.9 s
// unpruned, before the clamp). It is here for the rare case where exactness
// matters more than the tree size and -D ANN_NO_DOMINANCE is too slow.
//
// The axes:
//
//   copies/fives/ones  the score, NOT collapsed into one number. It is a
//              weighted sum and the parts buy different futures: a copy joker
//              feeds the cola engine through ann_saw_copy, a Baron or Mime is
//              five flat points that buy nothing later.
//
//   colas      banked Double Tags -- but c->colas alone is the wrong number.
//              Taking T2 moves the whole stock into pendingWidth and sets
//              c->colas to 0, so a branch that just cashed twenty colas into a
//              tag in flight reads as zero and would be dominated by one
//              holding a single banked cola. The key adds the in-flight tag
//              back: colas + (pendingWidth - 1), the -1 being the tag itself
//              rather than banked stock. Higher is better. (Note the stock and
//              the window are not 1:1: ann_colas_effective is integer
//              colas * 9 / 10, so 20 and 21 colas both buy a width of 19.)
//
//   seenCola   whether a Diet Cola has been met yet. ann_saw_copy only banks a
//              cola `if (c->seenCola ...)`: you need one in hand as the
//              template the copy jokers copy, so until then the engine is off
//              and copy jokers bank nothing. Diet Cola arrives through the
//              Uncommon identity stream, which is exactly what diverges
//              between branches, so two branches at one depth really can
//              differ on it. True is better.
//
//   uncAvail   Uncommons still in the pool. FEWER is better, not worse: the
//              whole engine is that keeping negative Uncommons shrinks the
//              pool and raises Diet Cola's share of it, so a drained pool is a
//              branch still scaling. An incumbent only dominates if its pool is
//              at least as drained.
//
//   noFarmBp/noFarmBs  a Negative Blueprint or Brainstorm is owned and kept, so
//              that kind stops being sold for Double Tags. The points are
//              already counted under copies, so the flag alone is future loss;
//              false is better.
//
// One "best so far" record per depth would not do, because with four axes the
// componentwise best is a state no branch ever actually reached, and pruning
// against a synthetic state can drop branches that nothing real dominates. So
// each depth keeps a small Pareto frontier instead.
// ---------------------------------------------------------------------------
// ON by default: -D ANN_NO_DOMINANCE turns it off and restores the exhaustive
// search. Turn it off when you need one named seed's score to be exactly right
// rather than a pool ranked correctly.
#if !defined(ANN_NO_DOMINANCE) && !defined(ANN_DOMINANCE)
#define ANN_DOMINANCE
#endif

#ifndef ANN_DOM_FRONTIER
#define ANN_DOM_FRONTIER 8
#endif

// The score is NOT one axis. It is a weighted sum, and the parts buy different
// futures: a copy joker feeds the cola engine through ann_saw_copy, a Baron or
// Mime is five flat points that buy nothing later. Collapsing them lets three
// copies dominate two copies and a Baron, and that single collapse is where
// most of the pruning damage was measured (-5 losses, i.e. exactly one
// Baron/Mime/DNA). So they are separate axes.
//
// The two farming flags are axes too, and they run the other way: negBlueprint
// means a Negative Blueprint is owned and kept, so Blueprints STOP being sold
// for Double Tags. The points are already counted under copies, so the flag on
// its own is pure future loss -- false is better.
typedef struct AnnDom {
    int copies, fives, ones;   // higher better
    int colas;                 // banked + in flight; higher better
    int uncAvail;              // lower better
    int seenCola;              // higher better
    int noFarmBp, noFarmBs;    // lower better: farming shut off for that kind
    int pendingWidth;          // kept separate from colas for the exact test
#if defined(ANN_DOM_AUDIT) || defined(ANN_DOM_EXACT)
    ulong locked[LOCKED_WORDS]; // the rest of the state: WHICH jokers are gone
#endif
} ann_dom;

inline void ann_dom_key(const ann_ctx* c, ann_dom* d) {
    d->copies = c->copies;
    d->fives = c->fives;
    d->ones = c->ones;
    d->colas = c->colas + (c->pendingWidth > 0 ? c->pendingWidth - 1 : 0);
    d->uncAvail = c->uncAvail;
    d->seenCola = c->seenCola ? 1 : 0;
    d->noFarmBp = c->negBlueprint ? 1 : 0;
    d->noFarmBs = c->negBrainstorm ? 1 : 0;
    d->pendingWidth = c->pendingWidth;
}

#if defined(ANN_DOM_AUDIT) || defined(ANN_DOM_EXACT)
inline void ann_dom_locks(ann_dom* d, const instance* inst) {
    for (int i = 0; i < LOCKED_WORDS; i++) d->locked[i] = inst->locked[i];
}
inline bool ann_dom_same_locks(const ann_dom* a, const ann_dom* b) {
    for (int i = 0; i < LOCKED_WORDS; i++) if (a->locked[i] != b->locked[i]) return false;
    return true;
}

// EXACT pruning (-D ANN_DOM_EXACT): a transposition, not a bet.
//
// Two branches that reach the same branch point in literally the same state --
// same lock set, same counters, same tag in flight -- have identical subtrees
// below them, because everything the walk reads from here on is a function of
// (seed, ante, lock set) and the counters. Dropping the second one cannot lose
// a point. The only thing it can change is which ann_log a pending window's
// points are REPORTED against, never the total.
//
// Everything in ann_ctx that is not compared here is either branch-independent
// at a given ante (overstock, overstockPlus, the voucher flags) or is
// bookkeeping for the printout (pendingLog).
inline bool ann_dom_identical(const ann_dom* a, const ann_dom* b) {
    return a->copies == b->copies && a->fives == b->fives && a->ones == b->ones &&
           a->colas == b->colas && a->uncAvail == b->uncAvail &&
           a->seenCola == b->seenCola && a->noFarmBp == b->noFarmBp &&
           a->noFarmBs == b->noFarmBs && a->pendingWidth == b->pendingWidth &&
           ann_dom_same_locks(a, b);
}
#endif

// Does `a` dominate `b`: at least as good on every axis, strictly better on one.
inline bool ann_dom_beats(const ann_dom* a, const ann_dom* b) {
    if (a->copies < b->copies || a->fives < b->fives || a->ones < b->ones ||
        a->colas < b->colas || a->seenCola < b->seenCola ||
        a->uncAvail > b->uncAvail ||
        a->noFarmBp > b->noFarmBp || a->noFarmBs > b->noFarmBs) return false;
    return a->copies > b->copies || a->fives > b->fives || a->ones > b->ones ||
           a->colas > b->colas || a->seenCola > b->seenCola ||
           a->uncAvail < b->uncAvail ||
           a->noFarmBp < b->noFarmBp || a->noFarmBs < b->noFarmBs;
}

inline long ann_dom_score(const ann_dom* d) {
    return (long)d->copies * ANN_W_COPY + (long)d->fives * ANN_W_FIVE + (long)d->ones * ANN_W_ONE;
}

// True to explore this branch, false to drop it. A surviving branch joins the
// frontier, evicting whatever it dominates. A full frontier only takes it in
// place of the lowest-scoring entry, and otherwise leaves the frontier alone --
// declining to record is always safe, because an entry that is not there simply
// prunes nothing.
inline bool ann_dom_admit(ann_dom* front, int* nfront, int depth, ann_ctx* c,
                          const instance* inst) {
    ann_dom mine;
    ann_dom_key(c, &mine);
#if defined(ANN_DOM_AUDIT) || defined(ANN_DOM_EXACT)
    ann_dom_locks(&mine, inst);
#else
    (void)inst;
#endif
    ann_dom* row = front + depth * ANN_DOM_FRONTIER;
    int n = nfront[depth];
#ifdef ANN_DOM_EXACT
    // Drop only an exact repeat of a state already explored. Lossless.
    for (int i = 0; i < n; i++) if (ann_dom_identical(&row[i], &mine)) {
#ifdef ANN_DOM_AUDIT
        c->audPrune++; c->audPruneSameLock++;
#endif
        return false;
    }
#else
    for (int i = 0; i < n; i++) if (ann_dom_beats(&row[i], &mine)) {
#ifdef ANN_DOM_AUDIT
        c->audPrune++;
        if (ann_dom_same_locks(&row[i], &mine)) c->audPruneSameLock++;
#endif
        return false;
    }
#endif
#ifndef ANN_DOM_EXACT
    int w = 0;
    for (int i = 0; i < n; i++) if (!ann_dom_beats(&mine, &row[i])) row[w++] = row[i];
    n = w;
#endif
    if (n < ANN_DOM_FRONTIER) {
        row[n++] = mine;
    } else {
        int lo = 0;
        for (int i = 1; i < n; i++) if (ann_dom_score(&row[i]) < ann_dom_score(&row[lo])) lo = i;
        if (ann_dom_score(&mine) > ann_dom_score(&row[lo])) row[lo] = mine;
    }
    nfront[depth] = n;
    return true;
}

// ---------------------------------------------------------------------------
// Depth-first search over the antes that offer a Negative Tag. Returns the best
// leaf score and fills bestChoice/bestLog with the line that reached it.
//
// Branching cannot be collapsed: a window's purchases lock Uncommons, which
// resamples later draws, so each branch really does see a different shop. What
// makes the tree affordable is that nothing but the lock set, the vouchers and
// a few counters survives an ante boundary, so a branch point costs one small
// snapshot and re-entering an ante from it redraws that ante exactly.
//
// With refChoice given, altBest[d*4+ch] also collects the best score reachable
// by following refChoice through the first d branch points and then taking ch
// instead -- the runner-up column of the explain output.
// ---------------------------------------------------------------------------
long ann_search(instance* inst, shop sh, double totalRate, int uncAvail0,
                const int* bpAnte, int M, const uchar* tagNeg,
                int* bestChoice, ann_log* bestLog,
                const int* refChoice, long* altBest,
                int forcedDepth, const int* forcedChoice,
                ann_ctx* bestCtxOut, ann_skel* sk) {
    ann_ante a;
    ann_snap snap[ANN_MAX_BRANCH_POINTS + 1];
    ann_log cur[ANN_MAX_BRANCH_POINTS];
    int choice[ANN_MAX_BRANCH_POINTS];
    int slot[ANN_MAX_BRANCH_POINTS];   // index into ANN_ORDER, not the choice itself
#ifdef ANN_DOMINANCE
    ann_dom front[(ANN_MAX_BRANCH_POINTS + 1) * ANN_DOM_FRONTIER];
    int nfront[ANN_MAX_BRANCH_POINTS + 1];
    for (int d = 0; d <= ANN_MAX_BRANCH_POINTS; d++) nfront[d] = 0;
#endif
    ann_log dump;
    ann_ctx ctx;

    ctx.colas = 0; ctx.copies = 0; ctx.fives = 0; ctx.ones = 0;
#ifdef ANN_EXPLAIN
    ctx.srcPack = 0; ctx.srcShop = 0; ctx.srcFarm = 0; ctx.srcFarmNeg = 0; ctx.skipEternal = 0;
    ctx.noTemplate = 0; ctx.noFarm = 0;
#endif
    ctx.seenCola = false; ctx.negBlueprint = false; ctx.negBrainstorm = false;
    ctx.pendingWidth = 0; ctx.pendingLog = 0;
    ctx.overstock = false; ctx.overstockPlus = false;
    ctx.uncAvail = uncAvail0;
#ifdef ANN_DOM_AUDIT
    ctx.audPrune = 0; ctx.audPruneSameLock = 0; ctx.audT1NoFit = 0;
    ctx.audT1NoFitWide = 0; ctx.audUncGateWide = 0;
#endif
#ifdef ANN_PROFILE
    ctx.draws = 0; ctx.depths = 0; ctx.passes = 0; ctx.antes = 0;
#endif
#ifdef ANN_NODE_PEAK
    ctx.nodePeak = 0;
#endif

    int firstBp = (M > 0) ? bpAnte[0] : ANN_LAST_ANTE + 1;
    for (int ante = 1; ante < firstBp; ante++)
        ann_ante_step(inst, &ctx, &a, ante, sh, totalRate, ANN_NONE, sk, &dump);
    if (M == 0) {
        if (bestCtxOut != 0) *bestCtxOut = ctx;
#ifdef ANN_NODE_PEAK
        return ctx.nodePeak;
#else
        return ann_score(&ctx);
#endif
    }

    long best = -1;
    ann_save(inst, &ctx, &snap[0]);
    int depth = 0;
    slot[0] = -1;
    while (depth >= 0) {
        int ante = bpAnte[depth];
        if (depth < forcedDepth) {
            // This branch point is pinned by the caller: one option, once.
            if (slot[depth] >= 0) { depth--; continue; }
            slot[depth] = 0;
            choice[depth] = forcedChoice[depth];
        } else {
            // ANN_ORDER, not the enum order: see the note on ANN_ORDER above.
            slot[depth]++;
            if (slot[depth] >= 4) { depth--; continue; }
            choice[depth] = ANN_ORDER[slot[depth]];
            if (!ann_offered(tagNeg[ante], ante, choice[depth])) continue;
        }

        ann_restore(inst, &ctx, &snap[depth]);
        if (!ann_ante_step(inst, &ctx, &a, ante, sh, totalRate, choice[depth], sk, &cur[depth]))
            continue;   // unavailable on this seed; prune rather than duplicate NONE
        int stop = (depth + 1 < M) ? bpAnte[depth + 1] : ANN_LAST_ANTE + 1;
        for (int t = ante + 1; t < stop; t++)
            ann_ante_step(inst, &ctx, &a, t, sh, totalRate, ANN_NONE, sk, &dump);

        if (depth + 1 < M) {
#ifdef ANN_DOMINANCE
            // The alternatives pass prunes identically to the search -- same
            // traversal, same frontier, so the same branches go. If it saw the
            // whole tree instead it could price an "alternative" above the
            // headline score, which reads as a bug rather than as a pruned run.
            if (!ann_dom_admit(front, nfront, depth + 1, &ctx, inst)) continue;
#endif
            ann_save(inst, &ctx, &snap[depth + 1]);
            depth++;
            slot[depth] = -1;
            continue;
        }

#ifdef ANN_NODE_PEAK
        long sc = ctx.nodePeak;
#else
        long sc = ann_score(&ctx);
#endif
        if (sc > best) {
            best = sc;
            for (int d = 0; d < M; d++) { bestChoice[d] = choice[d]; bestLog[d] = cur[d]; }
            if (bestCtxOut != 0) *bestCtxOut = ctx;   // for the explain breakdown
        }
        if (altBest != 0) {
            int d = 0;
            while (d < M && choice[d] == refChoice[d]) d++;
            if (d < M && sc > altBest[d * 4 + choice[d]]) altBest[d * 4 + choice[d]] = sc;
        }
    }
#ifdef ANN_DOM_AUDIT
    // 1 = branches pruned as dominated
    // 2 =   ...of those, ones whose lock set MATCHED the dominator's
    // 3 = T1 refusals because no window of that width fits
    // 4 =   ...of those, with width > 1, so the cola stock is what removed it
    // 5 = T1_UNC refusals by the 2*unc < width gate, with width > 1
    return ANN_DOM_AUDIT == 1 ? ctx.audPrune
         : ANN_DOM_AUDIT == 2 ? ctx.audPruneSameLock
         : ANN_DOM_AUDIT == 3 ? ctx.audT1NoFit
         : ANN_DOM_AUDIT == 4 ? ctx.audT1NoFitWide : ctx.audUncGateWide;
#endif
#ifdef ANN_PROFILE
    // 1 = pool draws, 2 = resample-depth iterations, 3 = refinement passes,
    // 4 = ante walks. Counters survive a branch restore, so these are the
    // whole seed's totals.
    return ANN_PROFILE == 1 ? ctx.draws
         : ANN_PROFILE == 2 ? ctx.depths
         : ANN_PROFILE == 3 ? ctx.passes : ctx.antes;
#endif
    return best;
}

#ifdef ANN_EXPLAIN
void ann_print_choice(int ch) {
    if (ch == ANN_T1_COPY)     printf("T1_COPY");
    else if (ch == ANN_T1_UNC) printf("T1_UNC ");
    else if (ch == ANN_T2)     printf("T2     ");
    else                       printf("NONE   ");
}

void ann_explain(long best, const int* bpAnte, int M,
                 const int* bestChoice, const ann_log* bestLog,
                 const long* altBest, const ann_ctx* bc) {
    // Where the score comes from, so the per-tag lines below add up to
    // something rather than leaving most of the total unexplained. Everything a
    // Negative Tag window turned Negative is charged to that tag; everything
    // else was already Negative when it was found.
    int tagged = 0;
    for (int d = 0; d < M; d++) tagged += bestLog[d].points;
#ifdef ANN_ETERNAL_ONLY
    printf("score %d  =  %d eternal copy x%d + %d eternal Baron/Mime x%d",
           (int)best, bc->copies, ANN_W_COPY, bc->fives, ANN_W_FIVE);
#else
    printf("score %d  =  %d copy x%d + %d Baron/Mime/DNA x%d",
           (int)best, bc->copies, ANN_W_COPY, bc->fives, ANN_W_FIVE);
#endif
#ifdef ANN_SCORE_COMMONS
    printf(" + %d Juggler/Drunkard x%d", bc->ones, ANN_W_ONE);
#endif
    printf("\n         of which  +%d from negative tags, +%d found already Negative\n",
           tagged, (int)best - tagged);
    printf("         %d Diet Cola(s) left unspent at the end\n", bc->colas);
    printf("         Double Tags over the run: %d Diet Cola from packs + %d from the shop"
           " + %d farmed off non-Negative copy jokers", bc->srcPack, bc->srcShop, bc->srcFarm);
#ifdef ANN_ETERNAL_ONLY
    printf(" + %d farmed off Negative non-Eternal copy jokers\n", bc->srcFarmNeg);
    printf("         %d Eternal non-Negative copy joker(s) passed over (cannot be sold)", bc->skipEternal);
#endif
    printf("\n         sellable copy jokers that farmed nothing: %d before the first Diet Cola,"
           " %d after a Negative one of that kind was kept\n", bc->noTemplate, bc->noFarm);
    printf("%d branch point(s):\n", M);
    for (int d = 0; d < M; d++) {
        const ann_log* g = &bestLog[d];
        int ch = bestChoice[d];
        printf("ante %2d  ", bpAnte[d]);
        ann_print_choice(ch);
        // `colas` is the raw stock; the width is 1 + 90% of it, so both are
        // shown rather than leaving the shortfall unexplained.
        if (ch == ANN_T1_COPY || ch == ANN_T1_UNC) {
            printf("  colas %d (x0.9 = %d) -> %d negatives, from shop card %d  (%d copy, %d uncommon)  = +%d",
                   g->colas, g->width - 1, g->width, g->startCard, g->copies, g->uncommons, g->points);
        } else if (ch == ANN_T2) {
            printf("  colas %d (x0.9 = %d) -> %d negatives, fires ante %d from card 0  = +%d",
                   g->colas, g->width - 1, g->width, bpAnte[d] + 1, g->points);
        } else {
            printf("  bank %d cola(s)", g->colas);
        }
        if (g->nitems > 0) {
            printf("  aiming for:");
            for (int i = 0; i < g->nitems; i++) { printf(" "); print_item((item)g->items[i]); }
        }
        printf("\n");
        if (g->lastCopyCard >= 0 && g->frameSize > 0) {
            // Showman only lets the window take copy jokers already owned; it
            // changes nothing else this model tracks, so it is narrative.
            printf("         showman: buy by frame %d (card %d), sell from frame %d (after card %d)\n",
                   g->startCard / g->frameSize, g->startCard,
                   g->lastCopyCard / g->frameSize + 1, g->lastCopyCard);
        }
        printf("         alternatives:");
        for (int k = 0; k <= ANN_T2; k++) {
            if (k == ch) continue;
            if (altBest[d * 4 + k] < 0) continue;
            printf("  ");
            ann_print_choice(k);
            printf(" %d", (int)altBest[d * 4 + k]);
        }
        printf("\n");
    }
}
#endif

#ifdef FILTER_USES_GROUP_SCRATCH
long filter(instance* inst, __local long* groupScratch) {
#else
long filter(instance* inst) {
#endif
    // Per-seed, so the flag reports this seed rather than any earlier one that
    // happened to run in the same work-item.
    inst->rngCache.reportedOverflow = false;
    for (int i = 0; i < (int)(sizeof(ANN_UPGRADE_VOUCHERS) / sizeof(item)); i++)
        i_lock(inst, ANN_UPGRADE_VOUCHERS[i]);
    ANN_APPLY(ANN_LOCKED_COMMONS, i_lock)
    ANN_APPLY(ANN_LOCKED_UNCOMMONS, i_lock)
    ANN_APPLY(ANN_LOCKED_RARES, i_lock)
    ANN_APPLY(ANN_UNLOCKED_COMMONS, i_unlock)
    ANN_APPLY(ANN_UNLOCKED_UNCOMMONS, i_unlock)
    ANN_APPLY(ANN_UNLOCKED_RARES, i_unlock)
    init_locks(inst, 1, false, false);
    ANN_APPLY(ANN_LOCKED_TAGS, i_lock)

    // Tag layout, once. Tags come off their own ante-keyed nodes and are drawn
    // against tag locks only; nothing this filter ever locks is a tag, so every
    // branch sees the same tags and one pre-pass finds every branch point.
    uchar tagNeg[ANN_LAST_ANTE + 1];
    int bpAnte[ANN_MAX_BRANCH_POINTS + 1];
    int M = 0;
    for (int ante = 1; ante <= ANN_LAST_ANTE; ante++) {
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        init_unlocks(inst, ante, false);
        uchar t = 0;
        if (next_tag(inst, ante) == Negative_Tag) t |= 1;
        if (next_tag(inst, ante) == Negative_Tag) t |= 2;
        tagNeg[ante] = t;
        if (ante < ANN_FIRST_ANTE) continue;
        // A second-slot tag at the last ante has no ante left to fire in.
        if ((t & 1) || ((t & 2) && ante < ANN_LAST_ANTE)) {
            if (M < ANN_MAX_BRANCH_POINTS) bpAnte[M] = ante;
            M++;
        }
    }
    if (M > ANN_MAX_BRANCH_POINTS) return ANN_OVER_BUDGET + (long)M;
#ifdef ANN_BRANCH_POINTS
    // Diagnostic: stop after the tag pre-pass and report how many branch points
    // the seed offers. Cost of a seed is exponential in this, so it is the one
    // number that predicts how long a pool will take.
    return (long)M;
#endif

    shop sh = get_shop_instance(inst);
    double totalRate = get_total_rate(sh);

    // One shop skeleton per ante, shared by every branch below it.
    ann_skel skel;
    ann_skel_init(&skel);
    ann_skel* sk = &skel;

#ifdef ANN_REPLAY_CHECK
    // Scaffolding for the claim the whole search rests on: an ante re-entered
    // from a snapshot redraws itself exactly. Walks every ante twice from the
    // same snapshot and returns 1 only if the two walks agree everywhere.
    // Build it with:  immolate --build_opts "-D ANN_REPLAY_CHECK" ...
    {
        ann_ante a1, a2;
        ann_ctx c1, c2;
        ann_log d1, d2;
        ann_snap at_ante;
        c1.colas = 0; c1.copies = 0; c1.fives = 0; c1.ones = 0;
        c1.pendingWidth = 0; c1.overstock = false; c1.overstockPlus = false;
        for (int ante = 1; ante <= ANN_LAST_ANTE; ante++) {
            ann_save(inst, &c1, &at_ante);
            ann_ante_step(inst, &c1, &a1, ante, sh, totalRate, ANN_NONE, (ann_skel*)0, &d1);
            ann_snap after; ann_save(inst, &c1, &after);
            ann_restore(inst, &c2, &at_ante);
            ann_ante_step(inst, &c2, &a2, ante, sh, totalRate, ANN_NONE, (ann_skel*)0, &d2);
            if (c2.colas != c1.colas || c2.copies != c1.copies || c2.fives != c1.fives ||
                c2.ones != c1.ones || a2.jokerCards != a1.jokerCards ||
                a2.eligCount != a1.eligCount) return 0;
            for (int j = 0; j < a1.jokerCards; j++)
                if (a2.rar[j] != a1.rar[j] || a2.ed[j] != a1.ed[j] ||
                    a2.ident[j] != a1.ident[j] || a2.cardIdx[j] != a1.cardIdx[j]) return 0;
            for (int w = 0; w < LOCKED_WORDS; w++)
                if (inst->locked[w] != after.locked[w]) return 0;
        }
        return 1;
    }
#endif

    int bestChoice[ANN_MAX_BRANCH_POINTS];
    ann_log bestLog[ANN_MAX_BRANCH_POINTS];
    ann_ctx bestCtx;
    bestCtx.copies = 0; bestCtx.fives = 0; bestCtx.ones = 0; bestCtx.colas = 0;
    for (int d = 0; d < ANN_MAX_BRANCH_POINTS; d++) bestChoice[d] = ANN_NONE;

#if defined(ANN_EXPLAIN) && !defined(GROUP_PER_SEED)
    instance pristine = *inst;   // ann_search leaves inst dirty
#endif
    int uncAvail0 = 0;
    for (int index = 1; index <= (int)UNCOMMON_JOKERS[0]; index++)
        if (!i_locked(inst, UNCOMMON_JOKERS[index])) uncAvail0++;

#ifdef ANN_INVARIANCE_CHECK
    // The gate under the skeleton cache: is the skeleton really independent of
    // which branch we are in? Walk every ante twice from the same state, the
    // second time with 20 extra Uncommons locked -- the one thing a branch can
    // do that the next one cannot -- and compare. Neither walk may use the
    // cache, or the second would simply read back the first.
    //
    //   immolate -f analyze_naneinf_negatives -s SEED -n 1 -g 1 -c 0 \
    //            --build_opts "-D ANN_INVARIANCE_CHECK"
    //
    // Returns the number of antes whose skeleton matched, so a pass over a pool
    // is "every seed scores ANN_LAST_ANTE - ANN_FIRST_ANTE + 1".
    {
        ann_ante a1, a2;
        ann_ctx c1, c2;
        ann_log d1, d2;
        ann_snap clean;
        int matched = 0, identDiff = 0;
        for (int ante = ANN_FIRST_ANTE; ante <= ANN_LAST_ANTE; ante++) {
            c1.colas = 0; c1.copies = 0; c1.fives = 0; c1.ones = 0;
            c1.seenCola = false; c1.negBlueprint = false; c1.negBrainstorm = false;
            c1.pendingWidth = 0; c1.pendingLog = 0; c1.uncAvail = uncAvail0;
            c1.overstock = false; c1.overstockPlus = false;
            ann_save(inst, &c1, &clean);

            ann_ante_step(inst, &c1, &a1, ante, sh, totalRate, ANN_NONE, (ann_skel*)0, &d1);

            ann_restore(inst, &c2, &clean);
            int locked = 0;
            for (int k = 1; k <= (int)UNCOMMON_JOKERS[0] && locked < 20; k++)
                if (!i_locked(inst, UNCOMMON_JOKERS[k])) { i_lock(inst, UNCOMMON_JOKERS[k]); locked++; }
            c2.uncAvail -= locked;
            ann_ante_step(inst, &c2, &a2, ante, sh, totalRate, ANN_NONE, (ann_skel*)0, &d2);

            bool same = (a1.jokerCards == a2.jokerCards) && (a1.eligCount == a2.eligCount)
                     && (a1.frameSize == a2.frameSize);
            for (int j = 0; same && j < a1.jokerCards; j++)
                same = (a1.cardIdx[j] == a2.cardIdx[j]) && (a1.rar[j] == a2.rar[j])
                    && (a1.ed[j] == a2.ed[j]);
            if (same) matched++;
            for (int j = 0; j < a1.jokerCards; j++) if (a1.ident[j] != a2.ident[j]) identDiff++;
            ann_restore(inst, &c1, &clean);
        }
        printf("skeleton identical in %d of %d antes; joker identities differing: %d\n",
               matched, ANN_LAST_ANTE - ANN_FIRST_ANTE + 1, identDiff);
        return matched;
    }
#endif

#if defined(ANN_ETERNAL_CHECK) && defined(ANN_ETERNAL_ONLY)
    // The Eternal bits against lib's own shop draw, shop_items_dense with
    // SHOP_STICKERS at Black Stake (Eternal on, Perishable and Rental off, so
    // its flag is exactly the poll). Identities are not drawn there, so every
    // slot reads as compatible and the poll is compared bare.
    //
    //   immolate -f analyze_naneinf_eternal -s SEED -n 1 -g 1 -c 0 \
    //            --build_opts "-D ANN_ETERNAL_CHECK"
    //
    // Returns 0 when every joker in antes ANN_FIRST_ANTE..ANN_LAST_ANTE agrees on
    // card type and sticker, otherwise the number that did not.
    {
        ann_ante a1;
        ann_ctx c1;
        ann_log d1;
        c1.colas = 0; c1.copies = 0; c1.fives = 0; c1.ones = 0;
        c1.seenCola = false; c1.negBlueprint = false; c1.negBrainstorm = false;
        c1.pendingWidth = 0; c1.pendingLog = 0; c1.uncAvail = uncAvail0;
        c1.overstock = false; c1.overstockPlus = false;
        set_stake(inst, Black_Stake);
        shopitem out[SHOP_MAX_ITEMS];
        int bad = 0, jokers = 0, eternals = 0;
        for (int ante = 1; ante <= ANN_LAST_ANTE; ante++) {
            ann_ante_step(inst, &c1, &a1, ante, sh, totalRate, ANN_NONE, (ann_skel*)0, &d1);
            if (ante < ANN_FIRST_ANTE) continue;
            int cards = ann_frames(ante) * a1.frameSize;
            inst->rngCache.nextFreeNode = 0;
            inst->rngCache.lastNode = -1;
            int j = 0;
            for (int base = 0; base < cards; base += SHOP_MAX_ITEMS) {
                int m = cards - base < SHOP_MAX_ITEMS ? cards - base : SHOP_MAX_ITEMS;
                shop_items_dense_window(inst, ante, m, out, SHOP_STICKERS);
                for (int i = 0; i < m; i++) {
                    if (out[i].type != ItemType_Joker) continue;
                    bool annEt = j < a1.jokerCards && a1.cardIdx[j] == base + i
                              && (a1.ed[j] & ANN_ED_ETERNAL) != 0;
                    if (j >= a1.jokerCards || a1.cardIdx[j] != base + i
                        || annEt != out[i].joker.stickers.eternal) bad++;
                    if (annEt) eternals++;
                    jokers++;
                    j++;
                }
            }
            if (j != a1.jokerCards) bad++;
        }
        printf("eternal check: %d jokers, %d eternal, %d mismatched\n", jokers, eternals, bad);
        return bad;
    }
#endif

#ifdef GROUP_PER_SEED
    // ---------------------------------------------------------------------
    // One work-GROUP per seed: every lane holds the same seed and takes a
    // share of the tree. Without this a seed is one work-item, so the search
    // is serial however wide the device is -- and an M=10 seed is 59,049 leaf
    // walks on a single thread, which on a consumer GPU (fp64 at 1/64 rate) is
    // slower than on one CPU core. The whole batch then waits on that thread.
    // Splitting the top of the tree across the group attacks the thing that
    // actually sets wall time.
    //
    // Split by branch-point PREFIX, not by leaf: the shortest prefix with at
    // least `lanes` combinations. Each lane still gets whole subtrees, so the
    // DFS keeps its shared-prefix saving underneath the split. The kernel takes
    // the max across lanes afterwards.
    // ---------------------------------------------------------------------
    int lane = (int)get_local_id(0);
    int lanes = (int)get_local_size(0);
    int splitDepth = 0;
    long combos = 1;
    while (splitDepth < M && combos < (long)lanes) {
        combos *= (long)ann_arity(tagNeg[bpAnte[splitDepth]], bpAnte[splitDepth]);
        splitDepth++;
    }

    // ann_search dirties only the lock set and the vouchers; no RNG state
    // survives an ante, so this ~140-byte snapshot is the whole reset.
    ann_ctx baseCtx;
    baseCtx.colas = 0; baseCtx.copies = 0; baseCtx.fives = 0; baseCtx.ones = 0;
    baseCtx.seenCola = false; baseCtx.negBlueprint = false; baseCtx.negBrainstorm = false;
    baseCtx.pendingWidth = 0; baseCtx.pendingLog = 0;
    baseCtx.overstock = false; baseCtx.overstockPlus = false;
    baseCtx.uncAvail = uncAvail0;
#ifdef ANN_NODE_PEAK
    baseCtx.nodePeak = 0;
#endif
    ann_snap base;
    ann_save(inst, &baseCtx, &base);

    long best = -1;
    int forced[ANN_MAX_BRANCH_POINTS];
#ifdef ANN_EXPLAIN
    // ann_search reports the best line of the ONE call it is given, so the
    // lane has to hold on to the best across its own combinations rather than
    // letting the last call overwrite them.
    int tryChoice[ANN_MAX_BRANCH_POINTS];
    ann_log tryLog[ANN_MAX_BRANCH_POINTS];
    ann_ctx tryCtx;
#endif
    for (long c = (long)lane; c < combos; c += (long)lanes) {
        long t = c;
        for (int d = splitDepth - 1; d >= 0; d--) {
            int ar = ann_arity(tagNeg[bpAnte[d]], bpAnte[d]);
            forced[d] = ann_choice_at(tagNeg[bpAnte[d]], bpAnte[d], (int)(t % (long)ar));
            t /= (long)ar;
        }
        ann_restore(inst, &baseCtx, &base);
#ifdef ANN_EXPLAIN
        long sc = ann_search(inst, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                             tryChoice, tryLog, (const int*)0, (long*)0,
                             splitDepth, forced, &tryCtx, sk);
        if (sc > best) {
            best = sc;
            bestCtx = tryCtx;
            for (int d = 0; d < M; d++) { bestChoice[d] = tryChoice[d]; bestLog[d] = tryLog[d]; }
        }
#else
        long sc = ann_search(inst, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                             bestChoice, bestLog, (const int*)0, (long*)0,
                             splitDepth, forced, (ann_ctx*)0, sk);
        if (sc > best) best = sc;
#endif
    }
#else
    long best = ann_search(inst, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                           bestChoice, bestLog,
                           (const int*)0, (long*)0, 0, (const int*)0, &bestCtx, sk);
#endif

#ifdef ANN_EXPLAIN
    {
        // Second pass: the winning line is known now, so every leaf can be
        // charged to the first branch point where it left that line.
        //
        // It costs a whole extra search, which on a seed with many branch
        // points is the difference between half a minute and a minute and a
        // half. -D ANN_NO_ALTS skips it and prints the winning line only.
        long altBest[ANN_MAX_BRANCH_POINTS * 4];
        for (int i = 0; i < ANN_MAX_BRANCH_POINTS * 4; i++) altBest[i] = -1;
        bool explainHere = true;
#ifdef GROUP_PER_SEED
        // Each lane searched a different share of the tree, so each holds the
        // best line of its own share only. Elect the lane whose share held the
        // winner; it is the only one with the state to print, and the only one
        // that prints. Every lane computes the same index from the same scratch
        // array, so nothing has to be broadcast to make the decision.
        int winner = ann_group_argmax(groupScratch, lane, lanes, best);
        explainHere = (lane == winner);

        // The alternatives column prices every leaf against the WINNING line,
        // so that line has to reach the lanes holding the other leaves. It is
        // M ints; the scratch array is one long per lane, so this needs a group
        // at least M lanes wide. Narrower groups keep the winning line and drop
        // the column rather than printing a wrong one.
        bool canAlt = (M <= lanes);
        int refChoice[ANN_MAX_BRANCH_POINTS];
        if (canAlt) {
            barrier(CLK_LOCAL_MEM_FENCE);
            if (lane == winner) for (int d = 0; d < M; d++) groupScratch[d] = (long)bestChoice[d];
            barrier(CLK_LOCAL_MEM_FENCE);
            for (int d = 0; d < M; d++) refChoice[d] = (int)groupScratch[d];
        }
#endif
#ifndef ANN_NO_ALTS
        int again[ANN_MAX_BRANCH_POINTS];
        ann_log againLog[ANN_MAX_BRANCH_POINTS];
#ifdef GROUP_PER_SEED
        if (canAlt) {
            // Same split as the search above, so between them the lanes cover
            // every leaf exactly once; each lane fills altBest for its own
            // share and the group folds them together with a max, which is
            // what altBest already is -- a per-(depth, choice) maximum.
            for (long c = (long)lane; c < combos; c += (long)lanes) {
                long t = c;
                for (int d = splitDepth - 1; d >= 0; d--) {
                    int ar = ann_arity(tagNeg[bpAnte[d]], bpAnte[d]);
                    forced[d] = ann_choice_at(tagNeg[bpAnte[d]], bpAnte[d], (int)(t % (long)ar));
                    t /= (long)ar;
                }
                ann_restore(inst, &baseCtx, &base);
                ann_search(inst, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                           again, againLog, refChoice, altBest,
                           splitDepth, forced, (ann_ctx*)0, sk);
            }
            for (int e = 0; e < M * 4; e++)
                altBest[e] = ann_group_max(groupScratch, lane, lanes, altBest[e]);
        }
#else
        ann_search(&pristine, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                   again, againLog, bestChoice, altBest, 0, (const int*)0, (ann_ctx*)0, sk);
#endif
#else
#ifndef GROUP_PER_SEED
        (void)pristine;
#endif
#endif
        if (explainHere)
            ann_explain(best, bpAnte, M, bestChoice, bestLog, altBest, &bestCtx);
    }
#endif
    if (inst->rngCache.reportedOverflow) return ANN_CACHE_OVERFLOW;
    return best;
}
// probe
