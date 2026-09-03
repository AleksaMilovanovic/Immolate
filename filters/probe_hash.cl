#include "lib/immolate.cl"
// Diagnostic, not a search filter. Prints what this device's compiler makes of
// the `1 << 32` in pseudohash (undefined in C; driver-dependent) and the
// resulting hash of the starting seed, so the effective value can be pinned.
// Run: immolate -f probe_hash -s 11111111 -n 1 -g 1 -c 5
long filter(instance* inst) {
    int k = 32;
    printf("shift_1_by_32=%d  hashedSeed(11111111)=%.17g\n", (1 << k), inst->hashedSeed);
    return 0;
}
