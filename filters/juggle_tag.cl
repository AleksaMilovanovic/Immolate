// 1 if the first tag of ante JT_ANTE (39 by default) is the Juggle Tag, else 0.
//
// Cheap: a tag comes off its own ante-keyed rng node, so the ante can be drawn
// on its own without walking any earlier one. The only thing the earlier antes
// contribute is lock state, and that is settled with no draws at all --
// init_locks/init_unlocks just set bits.
//
// Locks match filters/negative_tags.cl and the deep shop filters, which matters
// more than it looks: a locked tag is rerolled, so the wrong lock set draws a
// different tag here. init_locks gates the tags that are locked behind an ante
// and init_unlocks lifts them on schedule (all of them by ante 6), then
// JT_LOCKED_TAGS is the profile's own unearned tags -- edit it to match your
// profile, or leave it empty ({}) for a completed one.
#ifndef CACHE_SIZE
#define CACHE_SIZE 32
#endif
// No deck path here either; see the note in negative_tags.cl.
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef JT_ANTE
#define JT_ANTE 39
#endif
__constant item JT_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };

long filter(instance* inst) {
    init_locks(inst, 1, false, false);
    for (int ante = 1; ante <= JT_ANTE; ante++) init_unlocks(inst, ante, false);
    for (int i = 0; i < (int)(sizeof(JT_LOCKED_TAGS) / sizeof(item)); i++)
        i_lock(inst, JT_LOCKED_TAGS[i]);
    item tag = next_tag(inst, JT_ANTE);
#ifdef JT_RAW
    return (long)tag;   // diagnostic: the tag itself, to check the lock set
#else
    return tag == Juggle_Tag;
#endif
}
