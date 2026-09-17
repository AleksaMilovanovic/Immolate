// Bit-exactness probe for candidate ph_step / div_pos rewrites. Not a filter.
//
// Score = number of (variant, input) pairs whose result differs in ANY bit from
// the reference in lib/util.cl over PRB_K inputs per seed: a mix of realistic
// hash states (fract outputs), log-uniform magnitudes down to the 1e-37
// fallback, and the non-finite states (0, inf, NaN) that the NaN/inf analysis
// filters depend on. Run with -c 1 over a large -n: any printed seed is a
// counterexample and shows which variant (bit 0..3 of the score's low nibble).
#include "lib/immolate.cl"
#ifndef PRB_K
#define PRB_K 64
#endif

__constant double PRB_PI_POS[64] = {
    0x0.0p+0, 0x1.921fb54442d18p+1, 0x1.921fb54442d18p+2, 0x1.2d97c7f3321d2p+3,
    0x1.921fb54442d18p+3, 0x1.f6a7a2955385ep+3, 0x1.2d97c7f3321d2p+4, 0x1.5fdbbe9bba775p+4,
    0x1.921fb54442d18p+4, 0x1.c463abeccb2bbp+4, 0x1.f6a7a2955385ep+4, 0x1.1475cc9eedf00p+5,
    0x1.2d97c7f3321d2p+5, 0x1.46b9c347764a4p+5, 0x1.5fdbbe9bba775p+5, 0x1.78fdb9effea46p+5,
    0x1.921fb54442d18p+5, 0x1.ab41b09886feap+5, 0x1.c463abeccb2bbp+5, 0x1.dd85a7410f58cp+5,
    0x1.f6a7a2955385ep+5, 0x1.07e4cef4cbd98p+6, 0x1.1475cc9eedf00p+6, 0x1.2106ca4910069p+6,
    0x1.2d97c7f3321d2p+6, 0x1.3a28c59d5433bp+6, 0x1.46b9c347764a4p+6, 0x1.534ac0f19860cp+6,
    0x1.5fdbbe9bba775p+6, 0x1.6c6cbc45dc8dep+6, 0x1.78fdb9effea46p+6, 0x1.858eb79a20bafp+6,
    0x1.921fb54442d18p+6, 0x1.9eb0b2ee64e81p+6, 0x1.ab41b09886feap+6, 0x1.b7d2ae42a9152p+6,
    0x1.c463abeccb2bbp+6, 0x1.d0f4a996ed424p+6, 0x1.dd85a7410f58cp+6, 0x1.ea16a4eb316f5p+6,
    0x1.f6a7a2955385ep+6, 0x1.019c501fbace3p+7, 0x1.07e4cef4cbd98p+7, 0x1.0e2d4dc9dce4cp+7,
    0x1.1475cc9eedf00p+7, 0x1.1abe4b73fefb5p+7, 0x1.2106ca4910069p+7, 0x1.274f491e2111ep+7,
    0x1.2d97c7f3321d2p+7, 0x1.33e046c843286p+7, 0x1.3a28c59d5433bp+7, 0x1.40714472653efp+7,
    0x1.46b9c347764a4p+7, 0x1.4d02421c87558p+7, 0x1.534ac0f19860cp+7, 0x1.59933fc6a96c1p+7,
    0x1.5fdbbe9bba775p+7, 0x1.66243d70cb829p+7, 0x1.6c6cbc45dc8dep+7, 0x1.72b53b1aed992p+7,
    0x1.78fdb9effea46p+7, 0x1.7f4638c50fafbp+7, 0x1.858eb79a20bafp+7, 0x1.8bd7366f31c64p+7
};
__constant double PRB_PI_POS_FRACT[64] = {
    0x0.0p+0, 0x1.21fb54442d180p-3, 0x1.21fb54442d180p-2, 0x1.b2f8fe6643a40p-2,
    0x1.21fb54442d180p-1, 0x1.6a7a2955385e0p-1, 0x1.b2f8fe6643a40p-1, 0x1.fb77d3774eea0p-1,
    0x1.0fdaa22168c00p-3, 0x1.18eafb32caec0p-2, 0x1.a9e8a554e1780p-2, 0x1.1d7327bb7c000p-1,
    0x1.65f1fccc87480p-1, 0x1.ae70d1dd92900p-1, 0x1.f6efa6ee9dd40p-1, 0x1.fb73dffd48c00p-4,
    0x1.0fdaa22168c00p-2, 0x1.a0d84c437f500p-2, 0x1.18eafb32caec0p-1, 0x1.6169d043d6300p-1,
    0x1.a9e8a554e1780p-1, 0x1.f2677a65ecc00p-1, 0x1.d7327bb7c0000p-4, 0x1.06ca491006900p-2,
    0x1.97c7f3321d200p-2, 0x1.1462ceaa19d80p-1, 0x1.5ce1a3bb25200p-1, 0x1.a56078cc30600p-1,
    0x1.eddf4ddd3ba80p-1, 0x1.b2f1177237800p-4, 0x1.fb73dffd48c00p-3, 0x1.8eb79a20baf00p-2,
    0x1.0fdaa22168c00p-1, 0x1.5859773274080p-1, 0x1.a0d84c437f500p-1, 0x1.e95721548a900p-1,
    0x1.8eafb32caec00p-4, 0x1.e9532dda84800p-3, 0x1.85a7410f58c00p-2, 0x1.0b527598b7a80p-1,
    0x1.53d14aa9c2f00p-1, 0x1.9c501fbace300p-1, 0x1.e4cef4cbd9800p-1, 0x1.6a6e4ee726000p-4,
    0x1.d7327bb7c0000p-3, 0x1.7c96e7fdf6a00p-2, 0x1.06ca491006900p-1, 0x1.4f491e2111e00p-1,
    0x1.97c7f3321d200p-1, 0x1.e046c84328600p-1, 0x1.462ceaa19d800p-4, 0x1.c511c994fbc00p-3,
    0x1.73868eec94800p-2, 0x1.02421c8755800p-1, 0x1.4ac0f19860c00p-1, 0x1.933fc6a96c100p-1,
    0x1.dbbe9bba77500p-1, 0x1.21eb865c14800p-4, 0x1.b2f1177237800p-3, 0x1.6a7635db32400p-2,
    0x1.fb73dffd48c00p-2, 0x1.4638c50fafb00p-1, 0x1.8eb79a20baf00p-1, 0x1.d7366f31c6400p-1
};

// (a) table for pi*pos and fract(pi*pos)
inline double ph_step_tab(double num, int c, int pos) {
    double q = div_pos(1.1239285023, num);
    double pp = pos < 64 ? PRB_PI_POS[pos] : 3.141592653589793116*(pos);
    double ppf = pos < 64 ? PRB_PI_POS_FRACT[pos] : fract(3.141592653589793116*(pos));
    long int_part = (q*c*3.141592653589793116+pp)*PH_SCALE;
    double fract_part = fract(fract((q*c*3.141592653589793116)*PH_SCALE)+ppf);
    return fract(((double)(int_part)+fract_part)/PH_SCALE);
}
// (b) trunc instead of the fp64 -> int64 -> fp64 round trip
inline double ph_step_trunc(double num, int c, int pos) {
    double q = div_pos(1.1239285023, num);
    double x = (q*c*3.141592653589793116+3.141592653589793116*(pos))*PH_SCALE;
    double int_part = trunc(x);
    double fract_part = fract(fract((q*c*3.141592653589793116)*PH_SCALE)+fract((3.141592653589793116*(pos))*PH_SCALE));
    return fract((int_part+fract_part)/PH_SCALE);
}
// (c) NVIDIA: fp64 approximate reciprocal as the Newton seed instead of the f32 one
inline double div_pos_rcp64(double a, double b) {
    if (b < 1e-37) return a / b;
#ifdef __NV_CL_C_VERSION
    double r;
    asm("rcp.approx.ftz.f64 %0, %1;" : "=d"(r) : "d"(b));
#else
    double r  = (double)(1.0f / (float)b);
#endif
    double e0 = fma(-b, r, 1.0);
    double y1 = fma(e0, r, r);
    double e1 = e0 * e0;
    double y2 = fma(e1, y1, y1);
    double q  = a * y2;
    double rr = fma(-b, q, a);
    return fma(rr, y2, q);
}
inline double ph_step_rcp64(double num, int c, int pos) {
    double q = div_pos_rcp64(1.1239285023, num);
    long int_part = (q*c*3.141592653589793116+3.141592653589793116*(pos))*PH_SCALE;
    double fract_part = fract(fract((q*c*3.141592653589793116)*PH_SCALE)+fract((3.141592653589793116*(pos))*PH_SCALE));
    return fract(((double)(int_part)+fract_part)/PH_SCALE);
}
// (d) all three together
inline double ph_step_all(double num, int c, int pos) {
    double q = div_pos_rcp64(1.1239285023, num);
    double pp = pos < 64 ? PRB_PI_POS[pos] : 3.141592653589793116*(pos);
    double ppf = pos < 64 ? PRB_PI_POS_FRACT[pos] : fract(3.141592653589793116*(pos));
    double int_part = trunc((q*c*3.141592653589793116+pp)*PH_SCALE);
    double fract_part = fract(fract((q*c*3.141592653589793116)*PH_SCALE)+ppf);
    return fract((int_part+fract_part)/PH_SCALE);
}

long filter(instance* inst) {
    long bad = 0;
    // realistic chain: states are fract outputs, characters are the ones the
    // searcher hashes (seed chars '1'..'Z', name chars), positions 1..70
    double h = inst->hashedSeed;
    lrandom lr = randomseed(inst->hashedSeed);
    for (int k = 0; k < PRB_K; k++) {
        ulong r = (l_random(&lr) > 0.5) ? 0UL : 1UL; // burn to vary
        _randint(&lr);
        ulong bits = lr.out.ul;
        int c = (int)(bits % 3UL) == 0 ? (int)'1' + (int)((bits >> 8) % 35UL) : (int)'0' + (int)((bits >> 8) % 75UL);
        int pos = 1 + (int)((bits >> 16) % 70UL);
        // input: mostly the running state; sometimes a log-uniform tiny value or a special
        double num = h;
        ulong sel = (bits >> 24) & 15UL;
        if (sel == 0) num = ldexp(fract(h) + 1e-300, -(int)((bits >> 28) % 125UL)); // down to ~1e-37 and below
        else if (sel == 1) num = 0.0;
        else if (sel == 2) num = as_double(0x7FF0000000000000UL);               // +inf
        else if (sel == 3) num = as_double(0x7FF8000000000000UL | ((bits >> 32) & 0xFFFFFUL)); // NaN with payload
        else if (sel == 4) num = as_double(0xFFF8000000000000UL);              // -NaN
        else if (sel == 5) num = as_double((bits >> 12) | 1UL);                // arbitrary bits (any magnitude/sign)
        else if (sel == 6) num = 1e-37 * (1.0 + (double)((bits >> 32) & 7UL) * 0.01) - 3e-39 * (double)((bits >> 40) & 3UL); // fallback boundary
        double ref = ph_step(num, c, pos);
        if (as_ulong(ref) != as_ulong(ph_step_tab(num, c, pos)))   bad |= 1;
        if (as_ulong(ref) != as_ulong(ph_step_trunc(num, c, pos))) bad |= 2;
        if (as_ulong(ref) != as_ulong(ph_step_rcp64(num, c, pos))) bad |= 4;
        if (as_ulong(ref) != as_ulong(ph_step_all(num, c, pos)))   bad |= 8;
        h = (sel >= 1 && sel <= 4) ? fract(h * 1.72431234 + 2.134453429141) : ref; // keep the chain finite
        if (!(h == h) || h == as_double(0x7FF0000000000000UL)) h = fract(inst->hashedSeed + k * 0.001);
        (void)r;
    }
    return bad;
}
