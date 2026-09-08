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
// Each locked tag that comes up costs a resample node per ante and reroll
// depth: 38 antes x 2 tags with three tags locked exceeds the default 64.
// Must come before the include; lib/cache.cl sizes the node array there.
#define CACHE_SIZE 512
#define FILTER_USES_CUTOFF
#include "lib/immolate.cl"

#ifndef NT_MAX_ANTE
#define NT_MAX_ANTE 38
#endif
__constant item NT_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };
#define NT_NUM_LOCKED_TAGS (sizeof(NT_LOCKED_TAGS) / sizeof(NT_LOCKED_TAGS[0]))

long filter(instance* inst, long cutoff) {
    init_locks(inst, 1, false, false);
    for (int i = 0; i < (int)NT_NUM_LOCKED_TAGS; i++) i_lock(inst, NT_LOCKED_TAGS[i]);
    // Targets decoded from the cutoff. A negative or zero cutoff asks for
    // nothing, so nothing is decided early and the full count is returned.
    long need1 = cutoff > 0 ? cutoff / 100 : 0;
    long need2 = cutoff > 0 ? cutoff % 100 : 0;
    long negativeTags1 = 0;
    long negativeTags2 = 0;
    for (int ante = 1; ante <= NT_MAX_ANTE; ante++) {
        if (cutoff > 0) {
            // Passed: first-slot target met, and the second-slot one too if the
            // cutoff asked for any (score >= cutoff holds either way from here).
            if (negativeTags1 > need1 || (negativeTags1 == need1 && negativeTags2 >= need2)) break;
            // Failed: even a Negative Tag in every remaining first slot falls short.
            if (negativeTags1 + (NT_MAX_ANTE - ante + 1) < need1) break;
        }
        init_unlocks(inst, ante, false);
        if (next_tag(inst, ante) == Negative_Tag) negativeTags1++;
        if (next_tag(inst, ante) == Negative_Tag) negativeTags2++;
    }
    // We want to differentiate the tag position
    return negativeTags1 * 100 + negativeTags2;
}
