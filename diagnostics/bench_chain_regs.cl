// Microbenchmark, not a filter. One half of a pair with bench_chain_inst.
//
// Same RNG schedule as bench_chain_inst (38 antes, two tag draws each,
// Foil/Holographic/Polychrome rerolled through "_resample" nodes), but every
// piece of RNG state -- node states, per-length seed-suffix hashes, the Lua
// RNG -- lives in kernel registers instead of the `instance` struct, which
// sits in per-thread private (NVIDIA "local") memory. The arithmetic is copied
// operation for operation from rng_node_resolve / rng_node_advance / randchoice
// (lib/instance.cl), so the two halves produce identical scores; the only
// difference is where the state lives and that no key is built or scanned.
// The ratio inst/regs is therefore the share of kernel time spent on the
// instance/cache machinery rather than on the fp64 hash and RNG math.
//
// Resample node states use a small array indexed by depth; the compiler may
// place that in private memory too, but it is touched only on a reroll.
#define CACHE_SIZE 32
#define INSTANCE_NO_DECK
#include "lib/immolate.cl"

#ifndef BC_MAX_ANTE
#define BC_MAX_ANTE 38
#endif
#define BC_MAX_RESAMPLE 8

inline bool bc_rerolled(item t) {
    return t == Foil_Tag || t == Holographic_Tag || t == Polychrome_Tag;
}

// pseudohash state after the seed's characters, which sit at positions
// L+1..L+len of a node name of length L. Mirrors the seed part of
// rng_node_resolve; fully unrolled so ch[] stays in registers.
inline double bc_seed_hash(const char ch[8], int len, int L) {
    double h = 1;
    int pos = L + len;
    #pragma unroll
    for (int i = 7; i >= 0; i--) {
        if (i < len) h = ph_step(h, ch[i], pos--);
    }
    return h;
}

// Node name "Tag" + ante (+ "_resample" + (k+1) when k > 0), fed last
// character first on top of the seed-suffix state, as rng_node_resolve does.
inline double bc_node_hash(double h, int ante, int k) {
    int pos = 3 + dec_len(ante) + (k ? 9 + dec_len(k + 1) : 0);
    if (k) {
        h = ph_decimal_rev(h, &pos, k + 1);
        h = ph_cstr_rev(h, &pos, "_resample", 9);
    }
    h = ph_decimal_rev(h, &pos, ante);
    // S_Null contributes no characters.
    return ph_cstr_rev(h, &pos, "Tag", 3);
}

// rng_node_advance + randchoice on a register-resident node state.
inline item bc_draw(double* st, double hashedSeed) {
    *st = roundDigits(fract(*st * 1.72431234 + 2.134453429141), 13);
    lrandom lr = randomseed((*st + hashedSeed) / 2);
    return TAGS[l_randint(&lr, 1, TAGS[0])];
}

long filter(instance* inst) {
    const int len = inst->seed.len;
    char ch[8];
    #pragma unroll
    for (int i = 0; i < 8; i++) ch[i] = i < len ? s_char_at(&inst->seed, i) : 0;
    const double hs = inst->hashedSeed;
    // Seed-suffix hashes for the four name lengths this schedule produces
    // (4/5 for the tag node, 14/15 for its resample nodes), filled lazily
    // like seedHashByLen.
    double sh4 = 0, sh5 = 0, sh14 = 0, sh15 = 0;
    uint shv = 0;
    long n1 = 0, n2 = 0;
    for (int ante = 1; ante <= BC_MAX_ANTE; ante++) {
        const bool oneDigit = ante < 10;
        double base;
        if (oneDigit) { if (!(shv & 1)) { sh4 = bc_seed_hash(ch, len, 4); shv |= 1; } base = sh4; }
        else          { if (!(shv & 2)) { sh5 = bc_seed_hash(ch, len, 5); shv |= 2; } base = sh5; }
        double st = bc_node_hash(base, ante, 0);
        double rs[BC_MAX_RESAMPLE + 1];
        uint rv = 0;
        for (int slot = 0; slot < 2; slot++) {
            item t = bc_draw(&st, hs);
            for (int k = 1; bc_rerolled(t) && k <= BC_MAX_RESAMPLE; k++) {
                if (!((rv >> k) & 1)) {
                    double rbase;
                    if (oneDigit) { if (!(shv & 4)) { sh14 = bc_seed_hash(ch, len, 14); shv |= 4; } rbase = sh14; }
                    else          { if (!(shv & 8)) { sh15 = bc_seed_hash(ch, len, 15); shv |= 8; } rbase = sh15; }
                    rs[k] = bc_node_hash(rbase, ante, k);
                    rv |= 1u << k;
                }
                t = bc_draw(&rs[k], hs);
            }
            if (t == Negative_Tag) { if (slot == 0) n1++; else n2++; }
        }
    }
    return n1 * 100 + n2;
}
