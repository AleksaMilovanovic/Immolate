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
// Rares are never locked. Duplicate copy jokers are what Showman is bought for,
// and the model simply allows them (see ANN_SHOWMAN_SUPPRESSES_RESAMPLE).
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
// 4^10 leaves is already ~1e6 walks of a seed. Past this the seed is parked.
#ifndef ANN_MAX_BRANCH_POINTS
#define ANN_MAX_BRANCH_POINTS 10
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

// SHOWMAN. Bought before a copy-joker window and sold on the frame boundary
// after the last copy joker, so the window can take duplicates of copy jokers
// already owned. It is modelled as NARRATIVE ONLY: the explain output says
// which frames to buy and sell on, and the draw stream is untouched.
//
// That is not a shortcut, it is the only coherent option here. params.showman
// suppresses ALL resampling, including the Uncommon resampling the cola engine
// runs on, so switching it on inside a window would stop the pool shrinking
// exactly where the model wants it to. It also makes a window's contents depend
// on where the window starts, which is circular -- the start is chosen by
// reading those contents. And the duplication it exists to buy is already
// allowed, because Rares are never locked. So the purchase changes nothing that
// this model tracks, and the only honest thing to report is when to make it.

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
__constant item ANN_UNLOCKED_RARES[] = {Blueprint, Brainstorm};
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
inline bool annm_any(const ann_mask* m) {
    ulong any = 0UL;
    for (int i = 0; i < ANN_MASK_WORDS; i++) any |= m->w[i];
    return any != 0UL;
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
void ann_flush_pool(instance* inst, rtype rngType, rsrc src, int ante,
                    __constant item items[], int n, short* out,
                    const ann_keep* keeps, int keepCount) {
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
        if (!inst->params.showman && i_locked(inst, it)) annm_set(&pending, o);
    }

    for (int depth = 1; annm_any(&pending); depth++) {
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
                if (i_locked(inst, it)) annm_set(&next, o);
            }
        }
        pending = next;
    }
    ann_keeps_on(inst, keeps, keepCount);
    inst->rng = rng;
}

#define ANN_R_COMMON   0
#define ANN_R_UNCOMMON 1
#define ANN_R_RARE     2

#define ANN_ED_NEGATIVE 1
#define ANN_ED_ANY      2

#define ANN_NONE    0
#define ANN_T1_COPY 1
#define ANN_T1_UNC  2
#define ANN_T2      3

// Running totals that a branch carries across antes.
typedef struct AnnCtx {
#ifdef ANN_NODE_PEAK
    int nodePeak;   // measurement only; deliberately survives a branch restore
#endif
    int colas;
    int copies, fives, ones;
    int pendingWidth;   // a T2 tag taken last ante fires this ante at this width
    int uncAvail;       // Uncommons still in the pool, for ANN_LOCK_FLOOR
    bool overstock, overstockPlus;
} ann_ctx;

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
    *c = s->ctx;
#ifdef ANN_NODE_PEAK
    c->nodePeak = peak;   // a high-water mark, not branch state
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
    int eligCount;
} ann_ante;

// A Negative Tag window: `width` consecutive eligible shop jokers starting at
// eligible-target ordinal `start`, all of which must sit before `limitCards`.
typedef struct AnnWin { int start, width, limitCards; } ann_win;

// At most one keep per Uncommon in the pool, and a kept one never comes back.
#define ANN_MAX_KEEPS 80

// Is this shop joker inside a Negative Tag window? elig is -1 for a joker that
// already has an edition, and window starts are never negative, so those never
// match.
inline bool ann_is_target(const ann_ante* a, int slot, const ann_win* wins, int nwins) {
    for (int w = 0; w < nwins; w++)
        if (a->elig[slot] >= wins[w].start && a->elig[slot] < wins[w].start + wins[w].width)
            return true;
    return false;
}

// Points a single joker is worth once it is Negative.
inline int ann_value(item joker, bool* isCopy) {
    *isCopy = (joker == Blueprint || joker == Brainstorm);
    if (*isCopy) return ANN_W_COPY;
    if (joker == Baron || joker == DNA || joker == Mime || joker == Burglar) return ANN_W_FIVE;
#ifdef ANN_SCORE_COMMONS
    if (joker == Juggler || joker == Drunkard) return ANN_W_ONE;
#endif
    return 0;
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

// What the winning line did at one branch point. `items` names the scoring
// jokers the window actually turned Negative -- what the line is aiming for.
#define ANN_LOG_ITEMS 12
typedef struct AnnLog {
    int ante, choice, width, startCard, copies, uncommons, colas, nitems;
    int lastCopyCard, frameSize;
    short items[ANN_LOG_ITEMS];
} ann_log;

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
                   int* colasAfterPacks, bool spendColas,
                   ann_log* log) {
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
            if (r == Rarity_Rare)          joker = randchoice_common(inst, R_Joker_Rare, S_Buffoon, ante, RARE_JOKERS);
            else if (r == Rarity_Uncommon) joker = randchoice_common(inst, R_Joker_Uncommon, S_Buffoon, ante, UNCOMMON_JOKERS);
            else                           joker = randchoice_common(inst, R_Joker_Common, S_Buffoon, ante, COMMON_JOKERS);
            rr[j] = r;
            drawn[j] = joker;
            if (!inst->params.showman) i_lock(inst, joker); // temporary, as buffoon_pack does
        }
        for (int j = 0; j < _pack.size; j++) i_unlock(inst, drawn[j]);
        // Editions and scoring only after the temporary locks are lifted, so a
        // permanent lock taken here is not undone by the loop above.
        for (int j = 0; j < _pack.size; j++) {
            bool negative = next_joker_edition(inst, S_Buffoon, ante) == Negative;
            if (drawn[j] == Diet_Cola) { c->colas++; continue; }  // sold on sight
            if (!negative) continue;
            bool isCopy;
            ann_credit(c, ann_value(drawn[j], &isCopy), isCopy);
            // Kept, so it leaves the Uncommon pool. Pack jokers are never
            // Negative Tag targets -- the tag only reads the shop queue.
            if (rr[j] == Rarity_Uncommon) ann_keep_uncommon(inst, c, drawn[j]);
        }
    }

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

    lrandom scratch;
    rng_node_id ctNode = rng_node_resolve(inst,
        (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, ante}, 2);
    double ctState = inst->rngCache.nodes[ctNode].rngState;
    int jc = 0;
    for (int i = 0; i < cards; i++) {
        double cardType = ann_random(inst, &ctState, &scratch) * totalRate;
        if (get_item_type(sh, cardType) == ItemType_Joker) a->cardIdx[jc++] = (short)i;
    }
    inst->rngCache.nodes[ctNode].rngState = ctState;
    a->jokerCards = jc;
    if (jc == 0) return;

    rng_node_id rarNode = rng_node_resolve(inst,
        (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, ante, S_Shop}, 3);
    rng_node_id edNode = rng_node_resolve(inst,
        (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Edition, S_Shop, ante}, 3);
    double rarState = inst->rngCache.nodes[rarNode].rngState;
    double edState = inst->rngCache.nodes[edNode].rngState;
    int eligCount = 0;
    for (int j = 0; j < jc; j++) {
        double rp = ann_random(inst, &rarState, &scratch);
        a->rar[j] = rp > 0.95 ? ANN_R_RARE : (rp > 0.7 ? ANN_R_UNCOMMON : ANN_R_COMMON);
        // One poll decides the whole edition: Negative above 0.997, and any
        // edition at all above 0.96. Anything with an edition is passed over by
        // a Negative Tag without consuming it.
        double ep = ann_random(inst, &edState, &scratch);
        uchar e = 0;
        if (ep > 0.997) e |= ANN_ED_NEGATIVE;
        if (ep > 0.96) e |= ANN_ED_ANY;
        a->ed[j] = e;
        a->ident[j] = 0;
        if (e & ANN_ED_ANY) {
            a->elig[j] = -1;
        } else {
            a->elig[j] = (short)eligCount;
            a->eligSlot[eligCount] = (short)j;
            eligCount++;
        }
    }
    inst->rngCache.nodes[rarNode].rngState = rarState;
    inst->rngCache.nodes[edNode].rngState = edState;
    a->eligCount = eligCount;

    // ---- identities, pool by pool ----
    // Nothing below consumes a cache node: each pool is drawn depth-major and
    // every node is handed back (see ann_flush_pool).
    int n;

    n = 0;
    for (int j = 0; j < jc; j++) if (a->rar[j] == ANN_R_RARE) a->poolSlot[n++] = (short)j;
    ann_flush_pool(inst, R_Joker_Rare, S_Shop, ante, RARE_JOKERS, n, a->poolOut,
                   (const ann_keep*)0, 0);
    for (int o = 0; o < n; o++) a->ident[a->poolSlot[o]] = a->poolOut[o];

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
    ann_flush_pool(inst, R_Joker_Common, S_Shop, ante, COMMON_JOKERS, lastCommon, a->poolOut,
                   (const ann_keep*)0, 0);
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
        ann_flush_pool(inst, R_Joker_Uncommon, S_Shop, ante, UNCOMMON_JOKERS, n, a->poolOut,
                       keeps, keepCount);
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
            if (id == Diet_Cola) continue;   // always sold, so never kept
            int slot = a->poolSlot[o];
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
    for (int j = 0; j < jc; j++) {
        item id = (item)a->ident[j];
        if (id == Diet_Cola) { c->colas++; continue; }   // sold on sight
        bool target = ann_is_target(a, j, wins, nwins);
        if (!(a->ed[j] & ANN_ED_NEGATIVE) && !target) continue;

        bool isCopy;
        int value = ann_value(id, &isCopy);
        ann_credit(c, value, isCopy);
        if (target && log != 0) {
            if (value > 0 && log->nitems < ANN_LOG_ITEMS) log->items[log->nitems++] = (short)id;
            // Showman is sold on the first frame boundary after the last copy
            // joker the window takes.
            if (isCopy) log->lastCopyCard = a->cardIdx[j];
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
int ann_pick_window(const ann_ante* a, int width, int limitCards, int minStart,
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
            if (id == Blueprint || id == Brainstorm) copies++;
            if (a->rar[slot] == ANN_R_UNCOMMON) unc++;
        }
        bool better = byCopy ? (copies > bc || (copies == bc && unc > bu))
                             : (unc > bu || (unc == bu && copies > bc));
        if (best < 0 || better) { best = ws; bc = copies; bu = unc; }
    }
    *outCopies = bc;
    *outUnc = bu;
    return best;
}

// The choices an ante offers, in a stable order: NONE first, then whatever its
// tags allow. A flat combination number indexes the branch tree through these,
// which is what lets the tree be split across work-items.
inline int ann_arity(uchar tag, int ante) {
    int n = 1;                                        // NONE is always offered
    if (tag & 1) n += 2;                              // T1_COPY, T1_UNC
    if ((tag & 2) && ante < ANN_LAST_ANTE) n += 1;    // T2 needs a next ante
    return n;
}
inline int ann_choice_at(uchar tag, int ante, int i) {
    if (i == 0) return ANN_NONE;
    if (tag & 1) {
        if (i == 1) return ANN_T1_COPY;
        if (i == 2) return ANN_T1_UNC;
    }
    return ANN_T2;
}

inline bool ann_offered(uchar tag, int ante, int choice) {
    if (choice == ANN_NONE) return true;
    if (choice == ANN_T1_COPY || choice == ANN_T1_UNC) return (tag & 1) != 0;
    return (tag & 2) != 0 && ante < ANN_LAST_ANTE;   // T2 needs a next ante to fire in
}

// Walk one ante inside a branch: fire any window a second-slot tag left
// pending, then take `choice`. Returns false when the choice is not available
// on this seed (no copy joker in reach, or the Uncommon gate refuses), which
// prunes that subtree instead of duplicating a weaker line.
bool ann_ante_step(instance* inst, ann_ctx* c, ann_ante* a, int ante,
                   shop sh, double totalRate, int choice, ann_log* log) {
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
    if (c->pendingWidth > 0) {
        wins[nw].start = 0;
        wins[nw].width = c->pendingWidth;
        wins[nw].limitCards = 1 << 30;   // a second-slot window has no half limit
        nw++;
    }
    c->pendingWidth = 0;

    log->ante = ante;
    log->choice = choice;
    log->width = 0;
    log->startCard = -1;
    log->copies = 0;
    log->uncommons = 0;
    log->nitems = 0;
    log->lastCopyCard = -1;
    log->frameSize = 0;

    // For NONE and T2 this is the whole line. For a first-slot tag it also
    // scouts the queue the window will be chosen from.
    ann_ante_walk(inst, c, a, ante, sh, totalRate, wins, nw, &colasAfterPacks, false, log);
    log->colas = colasAfterPacks;
    log->frameSize = a->frameSize;

    if (choice == ANN_T1_COPY || choice == ANN_T1_UNC) {
        // Everything inside a pending window is already Negative, so a
        // first-slot window here starts after it.
        int minStart = nw > 0 ? wins[0].start + wins[0].width : 0;
        int width = 1 + colasAfterPacks;
        int copies = 0, unc = 0;
        int ws = ann_pick_window(a, width, a->halfCards, minStart,
                                 choice == ANN_T1_COPY, &copies, &unc);
        if (ws < 0) return false;
        // A copy-joker window holding no copy joker is just a worse NONE.
        if (choice == ANN_T1_COPY && copies < 1) return false;
        // Below half Uncommons the pool barely moves, and past the gate ante
        // there is no run left to spend the extra Diet Colas in.
        if (choice == ANN_T1_UNC && (ante > ANN_UNCOMMON_GATE_ANTE || 2 * unc < width)) return false;
        wins[nw].start = ws;
        wins[nw].width = width;
        wins[nw].limitCards = a->halfCards;
        nw++;

        // Commit: redraw the ante from its own snapshot with the window in
        // place. Its locks shift the stream, so the identities the window was
        // picked on are a guess past its start and only this walk is scored.
        ann_restore(inst, c, &start);
        c->pendingWidth = 0;
        log->nitems = 0;
        log->lastCopyCard = -1;
        ann_ante_walk(inst, c, a, ante, sh, totalRate, wins, nw, &colasAfterPacks, true, log);
        log->colas = colasAfterPacks;
        log->width = width;
        log->startCard = a->cardIdx[a->eligSlot[ws]];
        log->copies = copies;
        log->uncommons = unc;
    }

    if (choice == ANN_T2) {
        // Taken now: the banked colas are sold and chained now, and the tag
        // fires in the next ante.
        c->pendingWidth = 1 + c->colas;
        c->colas = 0;
        log->width = c->pendingWidth;
    }
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
                int forcedDepth, const int* forcedChoice) {
    ann_ante a;
    ann_snap snap[ANN_MAX_BRANCH_POINTS + 1];
    ann_log cur[ANN_MAX_BRANCH_POINTS];
    int choice[ANN_MAX_BRANCH_POINTS];
    ann_log dump;
    ann_ctx ctx;

    ctx.colas = 0; ctx.copies = 0; ctx.fives = 0; ctx.ones = 0;
    ctx.pendingWidth = 0; ctx.overstock = false; ctx.overstockPlus = false;
    ctx.uncAvail = uncAvail0;
#ifdef ANN_NODE_PEAK
    ctx.nodePeak = 0;
#endif

    int firstBp = (M > 0) ? bpAnte[0] : ANN_LAST_ANTE + 1;
    for (int ante = 1; ante < firstBp; ante++)
        ann_ante_step(inst, &ctx, &a, ante, sh, totalRate, ANN_NONE, &dump);
#ifdef ANN_NODE_PEAK
    if (M == 0) return ctx.nodePeak;
#else
    if (M == 0) return ann_score(&ctx);
#endif

    long best = -1;
    ann_save(inst, &ctx, &snap[0]);
    int depth = 0;
    choice[0] = -1;
    while (depth >= 0) {
        int ante = bpAnte[depth];
        if (depth < forcedDepth) {
            // This branch point is pinned by the caller: one option, once.
            if (choice[depth] >= 0) { depth--; continue; }
            choice[depth] = forcedChoice[depth];
        } else {
            choice[depth]++;
            if (choice[depth] > ANN_T2) { depth--; continue; }
            if (!ann_offered(tagNeg[ante], ante, choice[depth])) continue;
        }

        ann_restore(inst, &ctx, &snap[depth]);
        if (!ann_ante_step(inst, &ctx, &a, ante, sh, totalRate, choice[depth], &cur[depth]))
            continue;   // unavailable on this seed; prune rather than duplicate NONE
        int stop = (depth + 1 < M) ? bpAnte[depth + 1] : ANN_LAST_ANTE + 1;
        for (int t = ante + 1; t < stop; t++)
            ann_ante_step(inst, &ctx, &a, t, sh, totalRate, ANN_NONE, &dump);

        if (depth + 1 < M) {
            ann_save(inst, &ctx, &snap[depth + 1]);
            depth++;
            choice[depth] = -1;
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
        }
        if (altBest != 0) {
            int d = 0;
            while (d < M && choice[d] == refChoice[d]) d++;
            if (d < M && sc > altBest[d * 4 + choice[d]]) altBest[d * 4 + choice[d]] = sc;
        }
    }
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
                 const long* altBest) {
    printf("score %d over %d branch point(s)\n", (int)best, M);
    for (int d = 0; d < M; d++) {
        const ann_log* g = &bestLog[d];
        int ch = bestChoice[d];
        printf("ante %2d  ", bpAnte[d]);
        ann_print_choice(ch);
        if (ch == ANN_T1_COPY || ch == ANN_T1_UNC) {
            printf("  colas %2d -> %2d negatives, from shop card %d  (%d copy, %d uncommon)",
                   g->colas, g->width, g->startCard, g->copies, g->uncommons);
        } else if (ch == ANN_T2) {
            printf("  colas %2d -> %2d negatives, fires ante %d from card 0",
                   g->width - 1, g->width, bpAnte[d] + 1);
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

long filter(instance* inst) {
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
            ann_ante_step(inst, &c1, &a1, ante, sh, totalRate, ANN_NONE, &d1);
            ann_snap after; ann_save(inst, &c1, &after);
            ann_restore(inst, &c2, &at_ante);
            ann_ante_step(inst, &c2, &a2, ante, sh, totalRate, ANN_NONE, &d2);
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
    for (int d = 0; d < ANN_MAX_BRANCH_POINTS; d++) bestChoice[d] = ANN_NONE;

#ifdef ANN_EXPLAIN
    instance pristine = *inst;   // ann_search leaves inst dirty
#endif
    int uncAvail0 = 0;
    for (int index = 1; index <= (int)UNCOMMON_JOKERS[0]; index++)
        if (!i_locked(inst, UNCOMMON_JOKERS[index])) uncAvail0++;

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
    baseCtx.pendingWidth = 0; baseCtx.overstock = false; baseCtx.overstockPlus = false;
    baseCtx.uncAvail = uncAvail0;
#ifdef ANN_NODE_PEAK
    baseCtx.nodePeak = 0;
#endif
    ann_snap base;
    ann_save(inst, &baseCtx, &base);

    long best = -1;
    int forced[ANN_MAX_BRANCH_POINTS];
    for (long c = (long)lane; c < combos; c += (long)lanes) {
        long t = c;
        for (int d = splitDepth - 1; d >= 0; d--) {
            int ar = ann_arity(tagNeg[bpAnte[d]], bpAnte[d]);
            forced[d] = ann_choice_at(tagNeg[bpAnte[d]], bpAnte[d], (int)(t % (long)ar));
            t /= (long)ar;
        }
        ann_restore(inst, &baseCtx, &base);
        long sc = ann_search(inst, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                             bestChoice, bestLog, (const int*)0, (long*)0,
                             splitDepth, forced);
        if (sc > best) best = sc;
    }
#else
    long best = ann_search(inst, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                           bestChoice, bestLog,
                           (const int*)0, (long*)0, 0, (const int*)0);
#endif

#ifdef ANN_EXPLAIN
    {
        // Second pass: the winning line is known now, so every leaf can be
        // charged to the first branch point where it left that line.
        long altBest[ANN_MAX_BRANCH_POINTS * 4];
        for (int i = 0; i < ANN_MAX_BRANCH_POINTS * 4; i++) altBest[i] = -1;
        int again[ANN_MAX_BRANCH_POINTS];
        ann_log againLog[ANN_MAX_BRANCH_POINTS];
        ann_search(&pristine, sh, totalRate, uncAvail0, bpAnte, M, tagNeg,
                   again, againLog, bestChoice, altBest, 0, (const int*)0);
        ann_explain(best, bpAnte, M, bestChoice, bestLog, altBest);
    }
#endif
    if (inst->rngCache.reportedOverflow) return ANN_CACHE_OVERFLOW;
    return best;
}
