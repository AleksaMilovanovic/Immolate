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
// The batch below holds up to NT_CHUNK antes' tag nodes and their resample
// nodes live at once (one base node per ante plus one per (ante, depth)).
#ifndef CACHE_SIZE
#define CACHE_SIZE 256
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
#ifdef NT_NO_LOCKS
// Diagnostic only: no profile locks at all (and ante 1 drawn with the ante-2
// lock set), so no tag is ever rerolled. Not the game; for divergence probes.
__constant item NT_LOCKED_TAGS[] = { RETRY };
#define NT_NUM_LOCKED_TAGS 0
#else
__constant item NT_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };
#define NT_NUM_LOCKED_TAGS (sizeof(NT_LOCKED_TAGS) / sizeof(NT_LOCKED_TAGS[0]))
#endif

// Antes per depth-major batch. Nodes of a batch stay live together (see
// CACHE_SIZE above); the -c early exits are checked between batches.
#ifndef NT_CHUNK
#define NT_CHUNK 19
#endif
#ifdef NT_FIRST_SLOT_ONLY
#define NT_SLOTS 1
#else
#define NT_SLOTS 2
#endif

long filter(instance* inst, long cutoff) {
#ifndef NT_NO_LOCKS
    init_locks(inst, 1, false, false);
#endif
    for (int i = 0; i < (int)NT_NUM_LOCKED_TAGS; i++) i_lock(inst, NT_LOCKED_TAGS[i]);
    // Targets decoded from the cutoff. A negative or zero cutoff asks for
    // nothing, so nothing is decided early and the full count is returned.
    long need1 = cutoff > 0 ? cutoff / 100 : 0;
    long need2 = cutoff > 0 ? cutoff % 100 : 0;
    long negativeTags1 = 0;
    long negativeTags2 = 0;
    // Ante 1 has its own tag lock set (init_locks locks half the pool), so it
    // is drawn on its own, as a two-request depth-major batch: the reroll
    // chains of its two slots then advance together instead of one after the
    // other, and their resample nodes are created once for the warp.
    {
        int antes1[2] = { 1, 1 };
        item tags1[2];
        randchoice_common_batch(inst, R_Tags, S_Null, antes1, 0, NT_SLOTS, TAGS, tags1);
        if (tags1[0] == Negative_Tag) negativeTags1++;
#ifndef NT_FIRST_SLOT_ONLY
        if (tags1[1] == Negative_Tag) negativeTags2++;
#endif
    }
    // From ante 2 on the tag lock set is constant: init_unlocks(2) frees the
    // ante-1 tag locks and antes 3-6 only unlock bosses, which tag draws never
    // see. Apply them all now and re-assert the profile locks once.
    for (int ante = 2; ante <= 6; ante++) init_unlocks(inst, ante, false);
    for (int i = 0; i < (int)NT_NUM_LOCKED_TAGS; i++) i_lock(inst, NT_LOCKED_TAGS[i]);
    // Antes 2..NT_MAX_ANTE in depth-major batches (randchoice_common_batch):
    // every ante's base draws first, then each lane's still-locked draws at
    // depth 1, then depth 2, ... Exact: each ante's nodes are consumed in
    // slot order either way. Per warp this replaces "some lane rerolls" on
    // nearly every slot with the max over lanes of a binomial count.
    for (int a0 = 2; a0 <= NT_MAX_ANTE; a0 += NT_CHUNK) {
        if (cutoff > 0) {
            // Passed: first-slot target met, and the second-slot one too if the
            // cutoff asked for any (score >= cutoff holds either way from here).
            if (negativeTags1 > need1 || (negativeTags1 == need1 && negativeTags2 >= need2)) break;
            // Failed: even a Negative Tag in every remaining first slot falls short.
            if (negativeTags1 + (NT_MAX_ANTE - a0 + 1) < need1) break;
        }
        int a1 = a0 + NT_CHUNK - 1;
        if (a1 > NT_MAX_ANTE) a1 = NT_MAX_ANTE;
        int n = (a1 - a0 + 1) * NT_SLOTS;
        int antes[NT_CHUNK * 2];
        item tags[NT_CHUNK * 2];
        for (int ante = a0; ante <= a1; ante++) {
            for (int slot = 0; slot < NT_SLOTS; slot++) antes[(ante - a0) * NT_SLOTS + slot] = ante;
        }
        // Only ante-keyed nodes are ever created, so nothing from an earlier
        // batch is read again: discard the slots to keep the scan short.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        randchoice_common_batch(inst, R_Tags, S_Null, antes, 0, n, TAGS, tags);
        for (int k = 0; k < n; k += NT_SLOTS) {
            if (tags[k] == Negative_Tag) negativeTags1++;
#ifndef NT_FIRST_SLOT_ONLY
            if (tags[k + 1] == Negative_Tag) negativeTags2++;
#endif
        }
    }
    // We want to differentiate the tag position
    return negativeTags1 * 100 + negativeTags2;
}
