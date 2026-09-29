// Primitive-cost microbenchmarks. Not filters.
//
// Each prim_<kind>.cl defines one PRIM_<KIND> macro and includes this file.
// The filter runs PRIM_K dependent repetitions of that primitive per seed and
// folds the result into the returned long so nothing is dead code. Pass
// -DPRIM_K=<n> through --build_opts to change the repetition count; timing two
// values of PRIM_K gives the cost of one repetition as a slope, independent of
// the per-seed floor (seed derivation, i_init, kernel loop), which prim_empty
// measures on its own. Run with -c 999999999 so nothing prints.
//
// Every chain is made data-dependent on the previous repetition, as the
// production code is (a node's next state depends on its current one), so the
// slopes measure the same latency/throughput regime the kernel sees.
#ifndef PRIM_K
#define PRIM_K 32
#endif
#ifndef CACHE_SIZE
#define CACHE_SIZE 64
#endif
#include "lib/immolate.cl"

// randomseed without its 10-step Tausworthe warmup and without the draw: the
// fp64 seeding part alone. Copied from util.cl.
inline lrandom prim_randomseed_nowarm(double d) {
    lrandom lr;
    uint r = 0x11090601;
    for (int i = 0; i < 4; i++) {
        ulong u;
        uint m = 1 << (r&255);
        r >>= 8;
        d = d*3.14159265358979323846;
        d = d+2.7182818284590452354;
        lr.out.d = d;
        u = lr.out.ul;
        if (u<m) u+=m;
        lr.state[i] = u;
    }
    return lr;
}

long filter(instance* inst) {
    const double hs = inst->hashedSeed;
    long acc = 0;
#if defined(PRIM_EMPTY)
    // Per-seed floor: s_from_rank + i_init (8 ph_steps for the seed hash) + loop.
    acc = inst->seed.len + (hs > 0.5);
#elif defined(PRIM_PHSTEP)
    // One character of pseudohash: div_pos, 3 fract, 2 x 64-bit conversions.
    double h = hs;
    for (int k = 0; k < PRIM_K; k++) h = ph_step(h, 65 + (k & 15), k + 1);
    acc = (long)(h * 1e6);
#elif defined(PRIM_DIVPOS)
    // div_pos alone (+ fract, mul, add to keep h in (0.25, 0.75)).
    double h = hs * 0.5 + 0.25;
    for (int k = 0; k < PRIM_K; k++) { double q = div_pos(1.1239285023, h); h = fract(q) * 0.5 + 0.25; }
    acc = (long)(h * 1e6);
#elif defined(PRIM_FRACT)
    // fract(h*a+b): mul, add, floor, sub. The first half of rng_node_advance.
    double h = hs;
    for (int k = 0; k < PRIM_K; k++) h = fract(h * 1.72431234 + 2.134453429141);
    acc = (long)(h * 1e6);
#elif defined(PRIM_ADVANCE)
    // rng_node_advance on a register: fract + roundDigits(13) + (st+hs)/2.
    double st = hs, a = 0;
    for (int k = 0; k < PRIM_K; k++) { st = roundDigits(fract(st * 1.72431234 + 2.134453429141), 13); a += (st + hs) / 2; }
    acc = (long)(a * 1e6);
#elif defined(PRIM_CVT64)
    // fp64 -> int64 -> fp64 round trip (as in ph_step's int_part) plus mul, mul, add.
    double h = hs;
    for (int k = 0; k < PRIM_K; k++) { long i = (long)(h * 3.0); h = (double)i * 0.34 + 0.1; }
    acc = (long)(h * 1e6);
#elif defined(PRIM_RANDOMSEED)
    // Full randomseed (fp64 seeding + 10 warmup steps) + one draw, chained.
    double a = 0;
    for (int k = 0; k < PRIM_K; k++) { lrandom lr = randomseed(hs + a * 1e-3); a += l_random(&lr); }
    acc = (long)(a * 1e6);
#elif defined(PRIM_RSFP)
    // randomseed's fp64 seeding only (no warmup) + one draw, chained.
    double a = 0;
    for (int k = 0; k < PRIM_K; k++) { lrandom lr = prim_randomseed_nowarm(hs + a * 1e-3); a += l_random(&lr); }
    acc = (long)(a * 1e6);
#elif defined(PRIM_TAUS)
    // 11 Tausworthe steps per repetition on a register state: randomseed's
    // warmup + draw without the fp64 seeding.
    lrandom lr = randomseed(hs);
    ulong x = 0;
    for (int k = 0; k < PRIM_K; k++) { for (int j = 0; j < 11; j++) _randint(&lr); x ^= lr.out.ul; }
    acc = (long)(x & 0xFFFFFFUL);
#elif defined(PRIM_DRAW_REG)
    // A whole draw with register-resident state: advance + randomseed + randint
    // + one divergent __constant table read. No instance/cache machinery.
    double st = hs;
    for (int k = 0; k < PRIM_K; k++) {
        st = roundDigits(fract(st * 1.72431234 + 2.134453429141), 13);
        lrandom lr = randomseed((st + hs) / 2);
        acc += TAGS[l_randint(&lr, 1, TAGS[0])];
    }
#elif defined(PRIM_DRAW_INST)
    // The production draw on one cached node: key build, lastNode hit, advance
    // in local memory, randomseed, draw.
    for (int k = 0; k < PRIM_K; k++)
        acc += (long)(random(inst, (__private ntype[]){N_Type}, (__private int[]){R_Erratic}, 1) * 1000);
#elif defined(PRIM_NODE_HIT)
    // get_node_child on one node (lastNode hit + advance), no randomseed.
    double a = 0;
    for (int k = 0; k < PRIM_K; k++) a += get_node_child(inst, (__private ntype[]){N_Type}, (__private int[]){R_Erratic}, 1);
    acc = (long)(a * 1e6);
#elif defined(PRIM_NODE_CREATE)
    // PRIM_K distinct 3-part nodes: each is a full-scan miss over the nodes so
    // far plus a name hash of ~10-11 ph_steps (seed part cached per length).
    double a = 0;
    for (int k = 0; k < PRIM_K; k++)
        a += get_node_child(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Common, S_Shop, k + 1}, 3);
    acc = (long)(a * 1e6);
#elif defined(PRIM_NODE_CREATE_RESET)
    // Same names, but the cache is emptied before each: key build + name hash
    // with no scan at all.
    double a = 0;
    for (int k = 0; k < PRIM_K; k++) {
        inst->rngCache.nextFreeNode = 0;
        inst->rngCache.lastNode = -1;
        a += get_node_child(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Common, S_Shop, k + 1}, 3);
    }
    acc = (long)(a * 1e6);
#elif defined(PRIM_NODE_SCAN)
    // 32 live nodes, then PRIM_K lookups alternating between the two OLDEST, so
    // every lookup misses lastNode and walks ~31 keys before hitting.
    double a = 0;
    for (int j = 0; j < 32; j++)
        a += get_node_child(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Common, S_Shop, j + 1}, 3);
    for (int k = 0; k < PRIM_K; k++)
        a += get_node_child(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Common, S_Shop, 1 + (k & 1)}, 3);
    acc = (long)(a * 1e6);
#elif defined(PRIM_CONST_DIV) || defined(PRIM_CONST_UNI)
    // Dependent __constant table reads. DIV: every lane starts at its own index,
    // so the 32 addresses of a warp differ and the read serialises. UNI: every
    // lane of a group starts at the same index, so the addresses agree.
    const int n = COMMON_JOKERS[0];
#if defined(PRIM_CONST_DIV)
    int idx = (int)(get_global_id(0) % n) + 1;
#else
    int idx = (int)(get_group_id(0) % n) + 1;
#endif
    for (int k = 0; k < PRIM_K; k++) idx = (((int)COMMON_JOKERS[idx] * 31 + k) % n) + 1;
    acc = idx + (hs > 0.5);
#elif defined(PRIM_DFMA_PEAK)
    // 8 independent fp64 FMA chains: fp64 pipe throughput.
    double a0 = hs, a1 = hs + 0.1, a2 = hs + 0.2, a3 = hs + 0.3, a4 = hs + 0.4, a5 = hs + 0.5, a6 = hs + 0.6, a7 = hs + 0.7;
    for (int k = 0; k < PRIM_K; k++) {
        a0 = fma(a0, 1.0000001, 0.5); a1 = fma(a1, 1.0000001, 0.5); a2 = fma(a2, 1.0000001, 0.5); a3 = fma(a3, 1.0000001, 0.5);
        a4 = fma(a4, 1.0000001, 0.5); a5 = fma(a5, 1.0000001, 0.5); a6 = fma(a6, 1.0000001, 0.5); a7 = fma(a7, 1.0000001, 0.5);
    }
    acc = (long)((a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7) * 1e3);
#elif defined(PRIM_DFMA_DEP)
    // One fp64 FMA chain of 8*PRIM_K: fp64 latency exposure at this occupancy.
    double a0 = hs;
    for (int k = 0; k < 8 * PRIM_K; k++) a0 = fma(a0, 1.0000001, 0.5);
    acc = (long)(a0 * 1e3);
#elif defined(PRIM_IMAD_PEAK)
    // 8 independent 32-bit integer multiply-add chains: int32 pipe throughput.
    uint s = (uint)(hs * 1e9);
    uint x0 = s, x1 = s + 1, x2 = s + 2, x3 = s + 3, x4 = s + 4, x5 = s + 5, x6 = s + 6, x7 = s + 7;
    for (int k = 0; k < PRIM_K; k++) {
        x0 = x0 * 1103515245u + 12345u; x1 = x1 * 1103515245u + 12345u; x2 = x2 * 1103515245u + 12345u; x3 = x3 * 1103515245u + 12345u;
        x4 = x4 * 1103515245u + 12345u; x5 = x5 * 1103515245u + 12345u; x6 = x6 * 1103515245u + 12345u; x7 = x7 * 1103515245u + 12345u;
    }
    acc = (long)((x0 ^ x1 ^ x2 ^ x3 ^ x4 ^ x5 ^ x6 ^ x7) & 0xFFFFu);
#elif defined(PRIM_I64_TAUS)
    // One Tausworthe word step (64-bit shifts/xors/and) chained PRIM_K times.
    ulong z = as_ulong(hs) | 1UL;
    for (int k = 0; k < PRIM_K; k++) z = ((((z<<31)^z)>>45)^((z&((ulong)(long)-1<<1))<<18)) ^ (ulong)k;
    acc = (long)(z & 0xFFFFFFUL);
#elif defined(PRIM_LOCAL)
    // Dependent private-memory (NVIDIA local) load+store pairs through the
    // node array: the cost of touching `instance` state.
    for (int j = 0; j < CACHE_SIZE; j++) { inst->rngCache.nodes[j].key = (ulong)((j * 7 + 1) & (CACHE_SIZE - 1)); inst->rngCache.nodes[j].rngState = 0; }
    int idx = 0;
    double a = 0;
    for (int k = 0; k < PRIM_K; k++) {
        inst->rngCache.nodes[idx].rngState += hs;
        a += inst->rngCache.nodes[idx].rngState;
        idx = (int)inst->rngCache.nodes[idx].key;
    }
    acc = (long)(a * 1e3) + idx;
#elif defined(PRIM_SFROMRANK)
    // Seed derivation from a rank: eight 64-bit divisions by 35.
    long r = s_tell(&inst->seed);
    for (int k = 0; k < PRIM_K; k++) { seed s = s_from_rank(r + k); r += (long)s.data[0] + s.len; }
    acc = r & 0xFFFF;
#elif defined(PRIM_IINIT)
    // i_init on a per-repetition-distinct seed: the seed's own 8-character hash
    // plus the instance field initialisation, as paid once per seed by search().
    for (int k = 0; k < PRIM_K; k++) {
        seed s = inst->seed;
        s.data[0] = (s.data[0] + (ulong)k) % NUM_CHARS;
        i_init(inst, s);
        acc += (long)(inst->hashedSeed * 1e6);
    }
#elif defined(PRIM_SFROMRANK_INDEP)
    // s_from_rank on PRIM_K ranks that do not depend on each other: the
    // throughput cost, with the latency of one derivation hidden by the others.
    long r0 = s_tell(&inst->seed);
    for (int k = 0; k < PRIM_K; k++) { seed s = s_from_rank(r0 + k * 7919L); acc += (long)s.data[k & 7] + s.len; }
#elif defined(PRIM_STELL)
    // s_tell: eight 64-bit multiply-adds over the seed digits.
    seed s = inst->seed;
    long r = 0;
    for (int k = 0; k < PRIM_K; k++) { r += s_tell(&s); s.data[k & 7] = (ulong)(r & 31); }
    acc = r & 0xFFFF;
#elif defined(PRIM_DIVCREATE)
    // Node creations performed by only the first PRIM_ACTIVE lanes of each
    // warp (the rest idle): what a divergent creation costs the warp.
#ifndef PRIM_ACTIVE
#define PRIM_ACTIVE 32
#endif
    double a = 0;
    if ((get_local_id(0) & 31) < PRIM_ACTIVE) {
        for (int k = 0; k < PRIM_K; k++) {
            inst->rngCache.nextFreeNode = 0;
            inst->rngCache.lastNode = -1;
            a += get_node_child(inst, (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Common, S_Shop, k + 1}, 3);
        }
    }
    acc = (long)(a * 1e6);
#elif defined(PRIM_DIVDRAW)
    // Draws (cached node) performed by only the first PRIM_ACTIVE lanes.
#ifndef PRIM_ACTIVE
#define PRIM_ACTIVE 32
#endif
    if ((get_local_id(0) & 31) < PRIM_ACTIVE) {
        for (int k = 0; k < PRIM_K; k++)
            acc += (long)(random(inst, (__private ntype[]){N_Type}, (__private int[]){R_Erratic}, 1) * 1000);
    }
#else
#error "prim_common.cl: no PRIM_<KIND> defined"
#endif
    return acc;
}
