// How big is analyze_naneinf_negatives' search tree for a seed, WITHOUT
// searching it. Cost is exponential in the branch-point count, so this is the
// one number that says whether a seed is affordable before you launch it.
//
//   immolate -f naneinf_branch_tree -s SEED -n 1 -g 1 -c 0
//     -> SEED (leaves)
//   immolate -f naneinf_branch_tree -s SEED -n 1 -g 1 -c 0 \
//            --build_opts "-D NBT_ARITIES"
//     -> one line per branch point: its ante and how many choices it offers
//
// Over a range it is a cheap census: -c 1000000 lists the seeds whose trees are
// past a million leaves. The tag layout is drawn against tag locks only, and
// nothing analyze_naneinf_negatives locks is a tag, so this pre-pass sees
// exactly the branch points the real search would.
//
// Arity per branch point, mirroring ann_arity: NONE is always offered, a
// first-slot Negative Tag adds T1_COPY and T1_UNC, and a second-slot one adds
// T2 if there is a next ante for it to fire in. So a branch point is worth 2, 3
// or -- when BOTH tag slots are Negative -- 4, which is the case that makes a
// seed much more expensive than a count of branch points suggests.
//
// Keep these in step with the filter's own defaults.
#define CACHE_SIZE 64
#include "lib/immolate.cl"

#ifndef ANN_FIRST_ANTE
#define ANN_FIRST_ANTE 3
#endif
#ifndef ANN_LAST_ANTE
#define ANN_LAST_ANTE 38
#endif

__constant item NBT_LOCKED_TAGS[] = { Foil_Tag, Holographic_Tag, Polychrome_Tag };

long filter(instance* inst) {
    init_locks(inst, 1, false, false);
    for (int i = 0; i < (int)(sizeof(NBT_LOCKED_TAGS) / sizeof(item)); i++)
        i_lock(inst, NBT_LOCKED_TAGS[i]);

    long leaves = 1;
    int M = 0;
    for (int ante = 1; ante <= ANN_LAST_ANTE; ante++) {
        // Every node here is ante-keyed, so last ante's slots are unreachable.
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        init_unlocks(inst, ante, false);

        uchar t = 0;
        if (next_tag(inst, ante) == Negative_Tag) t |= 1;
        if (next_tag(inst, ante) == Negative_Tag) t |= 2;
        if (ante < ANN_FIRST_ANTE) continue;

        int arity = 1;
        if (t & 1) arity += 2;
        if ((t & 2) && ante < ANN_LAST_ANTE) arity += 1;
        if (arity == 1) continue;   // not a branch point

        M++;
        leaves *= (long)arity;
#ifdef NBT_ARITIES
        printf("bp %2d: ante %2d arity %d\n", M, ante, arity);
#endif
    }
    return leaves;
}
