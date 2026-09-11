// Restricted exact software binary64 for randomseed's positive finite domain.
// Multiplication and addition round separately to nearest-even, matching
// FP_CONTRACT OFF. Arithmetic is uint-limb based; ulong is used only to move
// binary64 bit patterns across the API boundary.
#define SOFT_PI_BITS 0x400921FB54442D18UL
#define SOFT_E_BITS  0x4005BF0A8B145769UL
#define SOFT_PI_SIG_HI 0x001921FBu
#define SOFT_PI_SIG_LO 0x54442D18u
#define SOFT_E_SIG_HI  0x0015BF0Au
#define SOFT_E_SIG_LO  0x8B145769u

inline ulong soft_pack_u64(uint lo, uint hi) {
    return ((ulong)hi << 32) | (ulong)lo;
}

inline void soft_add_word(uint* word, uint value, uint* carry) {
    uint before = *word;
    *word += value;
    *carry += *word < before;
}

inline ulong soft_mul_pi_bits(ulong bits) {
    if (bits == 0UL) return 0UL;

    uint xLo = (uint)bits;
    uint xHiBits = (uint)(bits >> 32);
    int xExp = (int)((xHiBits >> 20) & 0x7FFu) - 1023;
    uint xHi = (xHiBits & 0x000FFFFFu) | 0x00100000u;

    uint lo00 = xLo * SOFT_PI_SIG_LO;
    uint hi00 = mul_hi(xLo, SOFT_PI_SIG_LO);
    uint lo01 = xLo * SOFT_PI_SIG_HI;
    uint hi01 = mul_hi(xLo, SOFT_PI_SIG_HI);
    uint lo10 = xHi * SOFT_PI_SIG_LO;
    uint hi10 = mul_hi(xHi, SOFT_PI_SIG_LO);
    uint lo11 = xHi * SOFT_PI_SIG_HI;
    uint hi11 = mul_hi(xHi, SOFT_PI_SIG_HI);

    uint w0 = lo00;
    uint w1 = hi00;
    uint carry1 = 0;
    soft_add_word(&w1, lo01, &carry1);
    soft_add_word(&w1, lo10, &carry1);

    uint w2 = hi01;
    uint carry2 = 0;
    soft_add_word(&w2, hi10, &carry2);
    soft_add_word(&w2, lo11, &carry2);
    soft_add_word(&w2, carry1, &carry2);
    uint w3 = hi11 + carry2;

    uint shifted = (w3 >> 9) & 1u;
    int outExp = xExp + 1 + (int)shifted;
    uint qLo, qHi, guard;
    bool sticky;
    if (shifted == 0u) {
        qLo = (w1 >> 20) | (w2 << 12);
        qHi = (w2 >> 20) | (w3 << 12);
        guard = (w1 >> 19) & 1u;
        sticky = w0 != 0u || (w1 & 0x0007FFFFu) != 0u;
    } else {
        qLo = (w1 >> 21) | (w2 << 11);
        qHi = (w2 >> 21) | (w3 << 11);
        guard = (w1 >> 20) & 1u;
        sticky = w0 != 0u || (w1 & 0x000FFFFFu) != 0u;
    }

    if (guard && (sticky || (qLo & 1u))) {
        qLo++;
        if (qLo == 0u) qHi++;
    }
    if (qHi == 0x00200000u) {
        qHi = 0x00100000u;
        qLo = 0u;
        outExp++;
    }

    uint outHi = ((uint)(outExp + 1023) << 20) |
        (qHi & 0x000FFFFFu);
    return soft_pack_u64(qLo, outHi);
}

inline void soft_shift_right_jam(uint* lo, uint* hi, int distance) {
    uint oldLo = *lo;
    uint oldHi = *hi;
    if (distance == 0) return;
    if (distance < 32) {
        uint discarded = oldLo & ((1u << distance) - 1u);
        *lo = (oldLo >> distance) | (oldHi << (32 - distance));
        *hi = oldHi >> distance;
        if (discarded != 0u) *lo |= 1u;
        return;
    }
    if (distance == 32) {
        *lo = oldHi | (oldLo != 0u);
        *hi = 0u;
        return;
    }
    if (distance < 64) {
        int shift = distance - 32;
        uint discarded = oldHi & ((1u << shift) - 1u);
        *lo = (oldHi >> shift) | (oldLo != 0u || discarded != 0u);
        *hi = 0u;
        return;
    }
    *lo = oldLo != 0u || oldHi != 0u;
    *hi = 0u;
}

inline ulong soft_add_e_bits(ulong bits) {
    if (bits == 0UL) return SOFT_E_BITS;

    uint yLo = (uint)bits;
    uint yHiBits = (uint)(bits >> 32);
    int yExp = (int)((yHiBits >> 20) & 0x7FFu) - 1023;
    uint yHi = (yHiBits & 0x000FFFFFu) | 0x00100000u;

    uint aLo, aHi, bLo, bHi;
    int largeExp, distance;
    if (yExp >= 1) {
        aLo = yLo;
        aHi = yHi;
        bLo = SOFT_E_SIG_LO;
        bHi = SOFT_E_SIG_HI;
        largeExp = yExp;
        distance = yExp - 1;
    } else {
        aLo = SOFT_E_SIG_LO;
        aHi = SOFT_E_SIG_HI;
        bLo = yLo;
        bHi = yHi;
        largeExp = 1;
        distance = 1 - yExp;
    }

    uint aExtLo = aLo << 3;
    uint aExtHi = (aHi << 3) | (aLo >> 29);
    uint bExtLo = bLo << 3;
    uint bExtHi = (bHi << 3) | (bLo >> 29);
    soft_shift_right_jam(&bExtLo, &bExtHi, distance);

    uint sumLo = aExtLo + bExtLo;
    uint sumHi = aExtHi + bExtHi + (sumLo < aExtLo);
    if (sumHi & 0x01000000u) {
        uint jam = sumLo & 1u;
        sumLo = (sumLo >> 1) | (sumHi << 31);
        sumHi >>= 1;
        sumLo |= jam;
        largeExp++;
    }

    uint qLo = (sumLo >> 3) | (sumHi << 29);
    uint qHi = sumHi >> 3;
    uint grs = sumLo & 7u;
    if (grs > 4u || (grs == 4u && (qLo & 1u))) {
        qLo++;
        if (qLo == 0u) qHi++;
    }
    if (qHi == 0x00200000u) {
        qHi = 0x00100000u;
        qLo = 0u;
        largeExp++;
    }

    uint outHi = ((uint)(largeExp + 1023) << 20) |
        (qHi & 0x000FFFFFu);
    return soft_pack_u64(qLo, outHi);
}

inline lrandom soft_randomseed(double d) {
    lrandom lr;
    ulong bits = as_ulong(d);
    uint r = 0x11090601u;
    for (size_t i = 0; i < 4; i++) {
        uint m = 1u << (r & 255u);
        r >>= 8;
        bits = soft_mul_pi_bits(bits);
        bits = soft_add_e_bits(bits);
        if (bits < (ulong)m) bits += (ulong)m;
        lr.state[i] = bits;
    }
    lr.out.ul = bits;
    for (size_t i = 0; i < 10; i++) _randint(&lr);
    return lr;
}
