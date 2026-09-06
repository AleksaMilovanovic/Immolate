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
#include "lib/immolate.cl"

#ifndef NT_MAX_ANTE
#define NT_MAX_ANTE 38
#endif

long filter(instance* inst) {
    init_locks(inst, 1, false, false);
    long negativeTags = 0;
    for (int ante = 1; ante <= NT_MAX_ANTE; ante++) {
        init_unlocks(inst, ante, false);
        if (next_tag(inst, ante) == Negative_Tag) negativeTags++;
        if (next_tag(inst, ante) == Negative_Tag) negativeTags++;
    }
    return negativeTags;
}
