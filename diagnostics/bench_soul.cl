#include "lib/immolate.cl"
// Microbenchmark: bench_pack plus wr_filter's soul emulation, without the
// Perkeo draw and with the default 64-node cache. Isolates the soul polls'
// cost from the cache size and from next_joker. Run with -c 11.
#if V_AT_MOST(1,0,0,10)
    #define BS_SOUL_POLL(inst, rt, ante) random(inst, (__private ntype[]){N_Type, N_Type}, (__private int[]){R_Soul, rt}, 2)
#else
    #define BS_SOUL_POLL(inst, rt, ante) random(inst, (__private ntype[]){N_Type, N_Type, N_Ante}, (__private int[]){R_Soul, rt, ante}, 3)
#endif
long filter(instance* inst) {
    next_pack(inst, 1);
    pack p = pack_info(next_pack(inst, 1));
    if (p.type != Arcana_Pack && p.type != Spectral_Pack) return 0;
    bool soulLocked = i_locked(inst, The_Soul);
    bool bhLocked = i_locked(inst, Black_Hole);
    bool showman = inst->params.showman;
    if (p.type == Arcana_Pack) {
        for (int i = 0; i < p.size; i++) {
            if ((showman || !soulLocked) && BS_SOUL_POLL(inst, R_Tarot, 1) > 0.997) return 1;
        }
        return 0;
    }
    for (int i = 0; i < p.size; i++) {
        item forced = RETRY;
        if ((showman || !soulLocked) && BS_SOUL_POLL(inst, R_Spectral, 1) > 0.997) forced = The_Soul;
        if ((showman || !bhLocked) && BS_SOUL_POLL(inst, R_Spectral, 1) > 0.997) forced = Black_Hole;
        if (forced == The_Soul) return 1;
        if (forced == Black_Hole && !showman) bhLocked = true;
    }
    return 0;
}
