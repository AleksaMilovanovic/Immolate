// Seed-supplier filter: The Soul, and Perkeo from it, in the first two antes.
//
// Meant to be run once over a large range with --to to build a pool that later
// filters search with --from instead of walking every seed again:
//
//   immolate -f early_ante_perkeo -c 1 -n 100000000000 --to soul.seeds    (~4% pass)
//   immolate -f early_ante_perkeo -c 2 --from soul.seeds --to perkeo.seeds (~0.8%)
//   immolate -f some_other_filter --from perkeo.seeds
//
// Score:
//   0  no Soul in any pack checked
//   1  at least one pack contains The Soul
//   2  at least one of those Souls awards Perkeo
// so one walk at -c 1 gives the Soul pool and -c 2 the Perkeo pool.
//
// Packs checked: EAP_PACKS_PER_ANTE pack slots in each of antes 1 and 2, in
// the order the game rolls them (three shops of two packs each, no rerolls).
// The very first slot is the forced Buffoon Pack and can never hold a Soul.
// Only Arcana and Spectral packs are looked at; the check uses pack_has_soul
// (lib/functions.cl), which replays the soul polls exactly without drawing the
// tarot/spectral cards, so it costs one node lookup per candidate pack.
//
// A filter consuming this pool must reproduce the same RNG draws itself:
// filter() always starts from a fresh instance. Copy the loop below (or call
// pack_has_soul the same way) rather than assuming the Soul's position.
#include "lib/immolate.cl"

#ifndef EAP_PACKS_PER_ANTE
#define EAP_PACKS_PER_ANTE 6
#endif

long filter(instance* inst) {
    long score = 0;
    for (int ante = 1; ante <= 2; ante++) {
        for (int p = 0; p < EAP_PACKS_PER_ANTE; p++) {
            pack _pack = pack_info(next_pack(inst, ante));
            if (_pack.type != Arcana_Pack && _pack.type != Spectral_Pack) continue;
            if (!pack_has_soul(inst, _pack, ante)) continue;
            if (score < 1) score = 1;
            // Legendary jokers are not locked after being drawn in 1.0.1, so a
            // second Soul rolls independently; stop at the first Perkeo.
            if (next_joker(inst, S_Soul, ante) == Perkeo) return 2;
        }
    }
    return score;
}
