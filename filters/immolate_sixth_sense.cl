// Immolate from Sixth Sense in antes 1-3. Sixth Sense creates a spectral card
// when a hand of a single 6 is played; this checks the first SS_TRIGGERS (2)
// spectral cards it would create in each of antes 1 to SS_MAX_ANTE (3). Score
// is the number of those cards that are Immolate, so `-c 1` prints any hit.
//
// Cost: one RNG node per ante ("Spectral" + "sixth" + ante) and SS_TRIGGERS
// draws from it; six draws per seed at the defaults. Sixth Sense's cards are
// not soulable and no spectral is ever locked here, so next_spectral does no
// extra polls and no resampling. Nothing else needs to be simulated.
#include "lib/immolate.cl"

#ifndef SS_TRIGGERS
#define SS_TRIGGERS 2
#endif
#ifndef SS_MAX_ANTE
#define SS_MAX_ANTE 3
#endif

long filter(instance* inst) {
    long immolates = 0;
    for (int ante = 1; ante <= SS_MAX_ANTE; ante++) {
        for (int t = 0; t < SS_TRIGGERS; t++) {
            if (next_spectral(inst, S_Sixth_Sense, ante, false) == Immolate) immolates++;
        }
    }
    return immolates;
}
