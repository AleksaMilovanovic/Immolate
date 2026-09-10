// Diagnostic: raw RNG internals for one seed, printed as 32-bit hex halves so
// the output is exact on every platform (NVIDIA's printf mangles 64-bit
// formats). For each of a few node names it prints the node's pseudohash, the
// seeded LuaJIT state words, and the first random() output. Diffing this
// between two machines shows the first value where their arithmetic parts.
//   immolate -f rng_probe -s SEED -n 1 -g 1
#include "lib/immolate.cl"
#define P64(label, val) { dbllong _u; _u.d = (val); printf(label " %08x%08x\n", (uint)(_u.ul >> 32), (uint)(_u.ul & 0xffffffffUL)); }
#define P64U(label, v) { ulong _v = (v); printf(label " %08x%08x\n", (uint)(_v >> 32), (uint)(_v & 0xffffffffUL)); }
#define PROBE(label, ...) { \
    printf("-- " label "\n"); \
    double _h = get_node_child(inst, __VA_ARGS__); \
    P64("  node_child", _h); \
    lrandom _lr = randomseed(_h); \
    P64U("  state0", _lr.state[0]); P64U("  state1", _lr.state[1]); P64U("  state2", _lr.state[2]); P64U("  state3", _lr.state[3]); \
    P64("  random()", l_random(&_lr)); }
long filter(instance* inst) {
    P64("hashedSeed", inst->hashedSeed);
    PROBE("Voucher1",   (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Voucher, 1}, 2);
    PROBE("cdt1",       (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, 1}, 2);
    PROBE("rarity1sho", (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, 1, S_Shop}, 3);
    PROBE("Joker1sho1", (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Common, S_Shop, 1}, 3);
    PROBE("Joker2sho1", (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Uncommon, S_Shop, 1}, 3);
    PROBE("Joker3sho1", (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Rare, S_Shop, 1}, 3);
    PROBE("edisho1",    (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Joker_Edition, S_Shop, 1}, 3);
    PROBE("shop_pack1", (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Shop_Pack, 1}, 2);
    PROBE("Tag1",       (__private ntype[]){N_Type, N_Source, N_Ante}, (__private int[]){R_Tags, S_Null, 1}, 3);
    PROBE("cdt2",       (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, 2}, 2);
    PROBE("rarity2sho", (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, 2, S_Shop}, 3);
    PROBE("cdt3",       (__private ntype[]){N_Type, N_Ante}, (__private int[]){R_Card_Type, 3}, 2);
    PROBE("rarity3sho", (__private ntype[]){N_Type, N_Ante, N_Source}, (__private int[]){R_Joker_Rarity, 3, S_Shop}, 3);
    return 1;
}
