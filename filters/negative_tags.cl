// Counts Negative Tags. Score = number of Negative Tags among the two skip tags
// of every ante from 1 to NT_MAX_ANTE (38 by default), so `-c 3` prints seeds with at least
// three. Both tags of each ante are counted even though a run can only take one
// per ante; the score is "how many are on offer", which is what a supplier
// pool wants to sort by.
//
// Meant for pools: `immolate -f negative_tags -c 2 --from perkeo.seeds` runs
// only over seeds that already passed early_ante_perkeo. It works over a plain
// range too, but every seed then pays for NT_MAX_ANTE * 2 tag draws.
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
#define CACHE_SIZE 512

#include "lib/immolate.cl"

#ifndef NT_MAX_ANTE
#define NT_MAX_ANTE 38
#endif
__constant item NT_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };
#define NT_NUM_LOCKED_TAGS (sizeof(NT_LOCKED_TAGS) / sizeof(NT_LOCKED_TAGS[0]))

long filter(instance* inst) {
    init_locks(inst, 1, false, false);
    for (int i = 0; i < (int)NT_NUM_LOCKED_TAGS; i++) i_lock(inst, NT_LOCKED_TAGS[i]);
    long negativeTags1 = 0;
    long negativeTags2 = 0;
    for (int ante = 1; ante <= NT_MAX_ANTE; ante++) {
        init_unlocks(inst, ante, false);
        if (next_tag(inst, ante) == Negative_Tag) negativeTags1++;
        if (next_tag(inst, ante) == Negative_Tag) negativeTags2++;
    }
    // We want to differentiate the tag position
    return negativeTags1 * 100 + negativeTags2;
}
