// Counts Negative Tags. Score = first-slot count * 100 + second-slot count over
// antes 1 to NT_MAX_ANTE (38 by default), so `-c 400` prints seeds offering at
// least four first-slot Negative Tags (any second-slot count), and `-c 403` at
// least four first-slot with at least three second-slot. Both tags of each ante
// are counted even though a run can only take one per ante; the score is "how
// many are on offer", which is what a supplier pool wants to sort by.
//
// Early exit. The filter receives the -c cutoff (FILTER_USES_CUTOFF) and stops
// drawing as soon as the outcome is decided: once the first-slot count reaches
// the cutoff's hundreds digit (the seed passes; if the cutoff also asks for
// second-slot tags, once both are met), or once the antes left cannot supply
// the missing first-slot tags (the seed fails). Passing seeds therefore carry
// a LOWER BOUND, not the full count: rerun the survivors with -c 0 to get exact
// totals. With -c 0 nothing is ever decided early and every ante is drawn.
//
// NT_FIRST_SLOT_ONLY drops the second tag draw of every ante, halving the work.
// A cutoff like -c 400 asks for four FIRST-slot tags and no second-slot ones,
// so the second draw is computed and thrown away. Skipping it is exact for the
// first-slot count: the two draws share one ante-keyed node, and nothing from
// that node is read in any later ante, so a skipped draw cannot shift anything.
// The reported second-slot field is then 0 rather than the true count -- the
// score is already a lower bound whenever the cutoff decides early, and this
// makes the second field one too. Rerun survivors with -c 0 for exact totals.
//
// Meant for pools: `immolate -f negative_tags -c 400 --from perkeo.seeds` runs
// only over seeds that already passed early_ante_perkeo. It works over a plain
// range too, but every seed then pays for up to NT_MAX_ANTE * 2 tag draws.
//
// Locks follow the game: Negative Tag (and several others) cannot appear in
// ante 1, so init_locks is applied for ante 1 and init_unlocks per ante after
// that. Without them a rerolled ante-1 tag would land on the wrong item.
//
// NT_LOCKED_TAGS lists tags treated as never available, as if not yet
// unlocked on the profile: when the game rolls one it rerolls, which shifts
// every later tag draw, so a profile that has not unlocked Foil, Holographic
// and Polychrome Tags sees different Negative Tags than a completed one.
// Edit the list to match your profile; leave it empty ({}) for everything
// unlocked. Note init_unlocks(ante 2) re-enables Negative Tag; the list below
// is re-applied every ante so it is never undone by that.
//
// With the per-ante cache reset below, only one ante's nodes are ever live: two
// tag draws plus their resample chains, which with three tags locked is a
// handful. 64 is already generous. This is not just headroom -- the node array
// is the bulk of `instance`, which lives in private memory, so 512 slots cost
// 8KB per work-item and directly limit how many work-items stay resident.
// Must come before the include; lib/cache.cl sizes the node array there.
#ifndef CACHE_SIZE
#define CACHE_SIZE 32
#endif
// This filter never touches the deck path, so drop the 52-item starting deck
// from every work-item's instance. That is 208 bytes, and more to the point it
// removes a 52-element write loop from i_init that ran once per seed. The
// instance lives in local memory on NVIDIA, so its size is occupancy.
#define INSTANCE_NO_DECK
#define FILTER_USES_CUTOFF
#include "lib/immolate.cl"

#ifndef NT_MAX_ANTE
#define NT_MAX_ANTE 38
#endif
__constant item NT_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };
#define NT_NUM_LOCKED_TAGS (sizeof(NT_LOCKED_TAGS) / sizeof(NT_LOCKED_TAGS[0]))

// ---------------------------------------------------------------------------
// NT_FAST_TAGS: tag draws with nothing in local memory.
//
// The lib path routes every draw through the node cache -- scan for the node,
// create it, read and write its state -- and also reads hashedSeed, locked[]
// and inst->rng. `instance` does not fit in registers, so on a GPU every one of
// those is a local-memory round trip: about six per draw, ~230 per seed, and at
// 10M seeds/s that latency is the whole cost, not the arithmetic.
//
// None of it is needed here. With NT_FIRST_SLOT_ONLY an ante draws its tag node
// exactly once and never touches it again, so the node's state can be built in
// a register, used, and thrown away. The locked-tag test becomes a bit test on
// an index mask instead of a locked[] read.
//
// Two guards keep this exact rather than approximate:
//   - It REQUIRES NT_FIRST_SLOT_ONLY. With both slots drawn, the two draws
//     share one node and the second must continue the first's advanced state;
//     holding that per depth is the array this exists to avoid.
//   - Antes 1-6 keep the lib path. init_locks/init_unlocks open the ante-gated
//     tags on a schedule there, so the lock set is not yet just the profile's.
//     From ante 7 it is, and 32 of the 38 antes take the fast path.
#ifdef NT_FAST_TAGS
#ifndef NT_FIRST_SLOT_ONLY
#error "NT_FAST_TAGS requires NT_FIRST_SLOT_ONLY; see the note above"
#endif
#if NT_MAX_ANTE > 99
#error "NT_FAST_TAGS assumes a 1- or 2-digit ante"
#endif

// The seed's hash prefix depends on the node name only through its LENGTH, and
// a tag node takes just two lengths (1- and 2-digit antes). Two registers hold
// them, which is what the lib keeps in seedHashByLen -- an array in memory.
typedef struct NtHashCache { int len0, len1; double h0, h1; } nt_hash_cache;

inline double nt_seed_prefix(seed* sd, int nameLen) {
    int pos = nameLen + sd->len;
    double h = 1;
    for (int i = sd->len - 1; i >= 0; i--) h = ph_step(h, s_char_at(sd, i), pos--);
    return h;
}

// Initial state of the tag node for this ante, or its resample node at `depth`.
// Same construction as rng_node_resolve: the seed first, then the name's
// components in reverse order.
inline double nt_node_state(seed* sd, __constant char* src, int srcLen,
                            int ante, int depth, nt_hash_cache* hc) {
    int nameLen = 3 + srcLen + dec_len(ante) + (depth ? 9 + dec_len(depth + 1) : 0);
    double h;
    if (depth == 0 && nameLen == hc->len0)      h = hc->h0;
    else if (depth == 0 && nameLen == hc->len1) h = hc->h1;
    else {
        h = nt_seed_prefix(sd, nameLen);
        // Only the two base-node lengths are worth keeping; resample lengths
        // vary and would evict them for a 1-in-8 event.
        if (depth == 0) { if (hc->len0 < 0) { hc->len0 = nameLen; hc->h0 = h; }
                          else if (hc->len1 < 0) { hc->len1 = nameLen; hc->h1 = h; } }
    }
    int pos = nameLen;
    if (depth) { h = ph_decimal_rev(h, &pos, depth + 1); h = ph_cstr_rev(h, &pos, "_resample", 9); }
    h = ph_decimal_rev(h, &pos, ante);
    h = ph_cstr_rev(h, &pos, src, srcLen);
    h = ph_cstr_rev(h, &pos, "Tag", 3);
    return h;
}

inline item nt_fast_tag(instance* inst, int ante, nt_hash_cache* hc,
                        __constant char* src, int srcLen, uint lockedMask) {
    double hashedSeed = inst->hashedSeed;
    int count = (int)TAGS[0];
    double st = nt_node_state(&inst->seed, src, srcLen, ante, 0, hc);
    st = roundDigits(fract(st * 1.72431234 + 2.134453429141), 13);
    lrandom rng = randomseed((st + hashedSeed) / 2);
    int idx = (int)l_randint(&rng, 1, count);
    for (int depth = 1; (lockedMask >> (idx - 1)) & 1u; depth++) {
        double rs = nt_node_state(&inst->seed, src, srcLen, ante, depth, hc);
        rs = roundDigits(fract(rs * 1.72431234 + 2.134453429141), 13);
        rng = randomseed((rs + hashedSeed) / 2);
        idx = (int)l_randint(&rng, 1, count);
    }
    return TAGS[idx];
}
#endif // NT_FAST_TAGS

long filter(instance* inst, long cutoff) {
    init_locks(inst, 1, false, false);
    for (int i = 0; i < (int)NT_NUM_LOCKED_TAGS; i++) i_lock(inst, NT_LOCKED_TAGS[i]);
    // Targets decoded from the cutoff. A negative or zero cutoff asks for
    // nothing, so nothing is decided early and the full count is returned.
    long need1 = cutoff > 0 ? cutoff / 100 : 0;
    long need2 = cutoff > 0 ? cutoff % 100 : 0;
    long negativeTags1 = 0;
    long negativeTags2 = 0;
#ifdef NT_FAST_TAGS
    // Built once per seed and held in registers for the whole ante loop.
    nt_hash_cache hashCache; hashCache.len0 = -1; hashCache.len1 = -1;
    hashCache.h0 = 0; hashCache.h1 = 0;
    int srcLen = 0;
    __constant char* srcStr = source_cstr(S_Null, &srcLen);
    // Which TAGS indices are locked, as a bit mask: TAGS holds 24 entries, so
    // the whole lock test fits in one register instead of a locked[] read.
    uint lockedMask = 0;
    for (int i = 1; i <= (int)TAGS[0]; i++)
        for (int k = 0; k < (int)NT_NUM_LOCKED_TAGS; k++)
            if (TAGS[i] == NT_LOCKED_TAGS[k]) lockedMask |= 1u << (i - 1);
#endif
    for (int ante = 1; ante <= NT_MAX_ANTE; ante++) {
        if (cutoff > 0) {
            // Passed: first-slot target met, and the second-slot one too if the
            // cutoff asked for any (score >= cutoff holds either way from here).
            if (negativeTags1 > need1 || (negativeTags1 == need1 && negativeTags2 >= need2)) break;
            // Failed: even a Negative Tag in every remaining first slot falls short.
            if (negativeTags1 + (NT_MAX_ANTE - ante + 1) < need1) break;
        }
        // Every node this filter touches is ante-keyed -- the tag node and its
        // resample chain are (R_Tags, S_Null, ante[, depth]) -- so nothing from
        // an earlier ante is ever read again. Discarding the slots keeps
        // rng_node_resolve's LINEAR SCAN to the handful of nodes that are live,
        // instead of walking every node the run has created; by ante 38 that is
        // ~76 dead entries searched on every draw. Same change, and the same
        // reasoning, as the ante-local cache in deep_negative_shops.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        // init_unlocks only acts on antes 2-6; past that it is a call and five
        // comparisons to do nothing, 32 times per seed.
        if (ante <= 6) init_unlocks(inst, ante, false);
#ifdef NT_FAST_TAGS
        item tag = ante <= 6 ? next_tag(inst, ante)
                             : nt_fast_tag(inst, ante, &hashCache, srcStr, srcLen, lockedMask);
        if (tag == Negative_Tag) negativeTags1++;
#else
        if (next_tag(inst, ante) == Negative_Tag) negativeTags1++;
#endif
#ifndef NT_FIRST_SLOT_ONLY
        if (next_tag(inst, ante) == Negative_Tag) negativeTags2++;
#endif
    }
    // We want to differentiate the tag position
    return negativeTags1 * 100 + negativeTags2;
}
