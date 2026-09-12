// DIAGNOSTIC FIXTURE - prints the exact private-memory footprint of `instance`
// on the target device, so the occupancy arithmetic in the report can be checked
// against the real compiler's struct layout rather than PoCL's. Run with -n 1.
#ifndef PROBE_CACHE_SIZE
#define PROBE_CACHE_SIZE 256
#endif
#define CACHE_SIZE PROBE_CACHE_SIZE
#include "lib/immolate.cl"

long filter(instance* inst) {
    if (get_global_id(0) == 0) {
        printf("FOOTPRINT instance          = %u bytes  (CACHE_SIZE=%d, SEED_HASH_LENS=%d)\n",
               (uint)sizeof(instance), CACHE_SIZE, SEED_HASH_LENS);
        printf("FOOTPRINT   seed            = %u\n", (uint)sizeof(seed));
        printf("FOOTPRINT   cache           = %u  (nodes[] = %u, rnginfo = %u)\n",
               (uint)sizeof(cache), (uint)(sizeof(rnginfo) * CACHE_SIZE), (uint)sizeof(rnginfo));
        printf("FOOTPRINT   lrandom rng     = %u\n", (uint)sizeof(lrandom));
        printf("FOOTPRINT   locked[]        = %u  (LOCKED_WORDS=%d, ITEMS_END=%d)\n",
               (uint)(sizeof(ulong) * LOCKED_WORDS), LOCKED_WORDS, (int)ITEMS_END);
        printf("FOOTPRINT   seedHashByLen[] = %u\n", (uint)(sizeof(double) * SEED_HASH_LENS));
        printf("FOOTPRINT   instance_params = %u\n", (uint)sizeof(instance_params));
        printf("FOOTPRINT   item            = %u\n", (uint)sizeof(item));
    }
    return 0;
}
