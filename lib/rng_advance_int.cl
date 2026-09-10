#ifndef IMMOLATE_RNG_ADVANCE_INT_CL
#define IMMOLATE_RNG_ADVANCE_INT_CL

// Prototype only: exact decimal candidate for the 13-digit RNG-node recurrence.
// This file is included by validation/benchmark filters, not by lib/immolate.cl.
#define RNG13_BASE 10000U
#define RNG13_SCALE 10000000000000UL
#define RNG13_DENOM 100000000U
#define RNG13_HALF 50000000U
#define RNG13_GUARD_MARGIN 1562500U
#define RNG13_MISMATCH_SENTINEL 1000000000L

typedef struct RNG13State {
    uint d0;
    uint d1;
    uint d2;
    uint d3;
} rng13_state;

typedef struct RNG13Candidate {
    rng13_state state;
    uint remainder;
    bool safe;
} rng13_candidate;

typedef struct RNG13Step {
    rng13_state state;
    bool usedFastPath;
} rng13_step;

inline rng13_state rng13_from_ulong(ulong k) {
    rng13_state out;
    out.d0 = (uint)(k % RNG13_BASE);
    k /= RNG13_BASE;
    out.d1 = (uint)(k % RNG13_BASE);
    k /= RNG13_BASE;
    out.d2 = (uint)(k % RNG13_BASE);
    out.d3 = (uint)(k / RNG13_BASE);
    return out;
}

inline uint rng13_mix32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    return x ^ (x >> 16);
}

inline rng13_state rng13_validation_state(ulong counter) {
    // Shared deterministic corpus for the validator and paired benchmarks. The
    // first four counters force decimal-grid endpoints; the rest independently
    // mix the counter into each base-10,000 limb.
    if (counter == 0UL) return (rng13_state){0U, 0U, 0U, 0U};
    if (counter == 1UL) return (rng13_state){0U, 0U, 0U, 10U};
    if (counter == 2UL) return (rng13_state){9999U, 9999U, 9999U, 9U};
    if (counter == 3UL) return (rng13_state){1U, 0U, 0U, 0U};

    uint lo = (uint)counter;
    uint hi = (uint)(counter >> 32);
    uint x = lo ^ (hi * 0x9e3779b9U) ^ 0xa511e9b3U;
    uint v0 = rng13_mix32(x + 0x9e3779b9U);
    uint v1 = rng13_mix32(x + 0x3c6ef372U);
    uint v2 = rng13_mix32(x + 0xdaa66d2bU);
    uint v3 = rng13_mix32(x + 0x78dde6e4U);
    rng13_state out;
    out.d0 = v0 - (v0 / RNG13_BASE) * RNG13_BASE;
    out.d1 = v1 - (v1 / RNG13_BASE) * RNG13_BASE;
    out.d2 = v2 - (v2 / RNG13_BASE) * RNG13_BASE;
    out.d3 = v3 - (v3 / 10U) * 10U;
    return out;
}

inline void rng13_add_product(uint* lo, uint* hi, uint a, uint b) {
    uint addLo = a * b;
    uint addHi = mul_hi(a, b);
    uint oldLo = *lo;
    *lo += addLo;
    *hi += addHi + (*lo < oldLo);
}

inline ulong rng13_to_ulong(rng13_state state) {
    // d0 + d1*10^4 fits in one word. Add d2*10^8 and d3*10^12 as
    // split 32-bit products, then join the two words without integer division.
    uint lo = state.d0 + state.d1 * RNG13_BASE;
    uint hi = 0;
    rng13_add_product(&lo, &hi, state.d2, 100000000U);
    rng13_add_product(&lo, &hi, state.d3, 0xd4a51000U);
    hi += state.d3 * 0xe8U;
    return upsample(hi, lo);
}

inline double rng13_to_double(rng13_state state) {
    return div_1e13(convert_double(rng13_to_ulong(state)));
}

inline ulong rng13_native_next_k(double state) {
    // Keep the required two binary64 roundings separate. FP_CONTRACT is OFF.
    double stepped = state * 1.72431234;
    stepped = stepped + 2.134453429141;
    return convert_ulong(round(fract(stepped) * 1e13));
}

inline double rng13_native_next(double state) {
    return div_1e13(convert_double(rng13_native_next_k(state)));
}

inline rng13_candidate rng13_decimal_candidate(rng13_state state) {
    // Base-10,000 convolution by 172431234 = [1234, 7243, 1].
    // Dividing by 10^8 discards the two low normalized limbs.
    uint a0 = state.d0 * 1234U;
    uint a1 = state.d0 * 7243U + state.d1 * 1234U;
    uint a2 = state.d0 + state.d1 * 7243U + state.d2 * 1234U;
    uint a3 = state.d1 + state.d2 * 7243U + state.d3 * 1234U;
    uint a4 = state.d2 + state.d3 * 7243U;
    uint a5 = state.d3;

    uint carry = a0 / RNG13_BASE;
    uint p0 = a0 - carry * RNG13_BASE;
    a1 += carry;
    carry = a1 / RNG13_BASE;
    uint p1 = a1 - carry * RNG13_BASE;
    a2 += carry;
    carry = a2 / RNG13_BASE;
    uint p2 = a2 - carry * RNG13_BASE;
    a3 += carry;
    carry = a3 / RNG13_BASE;
    uint p3 = a3 - carry * RNG13_BASE;
    a4 += carry;
    carry = a4 / RNG13_BASE;
    uint p4 = a4 - carry * RNG13_BASE;
    uint p5 = a5 + carry;

    uint remainder = p0 + p1 * RNG13_BASE;

    // Add 1344534291410 = [1410, 3429, 3445, 1] to the quotient.
    uint q0 = p2 + 1410U;
    carry = q0 / RNG13_BASE;
    q0 -= carry * RNG13_BASE;
    uint q1 = p3 + 3429U + carry;
    carry = q1 / RNG13_BASE;
    q1 -= carry * RNG13_BASE;
    uint q2 = p4 + 3445U + carry;
    carry = q2 / RNG13_BASE;
    q2 -= carry * RNG13_BASE;
    uint q3 = p5 + 1U + carry;

    // The unreduced value is below 2*10^13, so one subtraction is enough.
    if (q3 >= 10U) q3 -= 10U;

    uint distance = remainder > RNG13_HALF
        ? remainder - RNG13_HALF
        : RNG13_HALF - remainder;
    bool nearHalf = distance <= RNG13_GUARD_MARGIN;
    bool nearZeroWrap = q0 == 0U && q1 == 0U && q2 == 0U && q3 == 0U
        && remainder <= RNG13_GUARD_MARGIN;
    bool nearTopWrap = q0 == 9999U && q1 == 9999U && q2 == 9999U && q3 == 9U
        && remainder >= RNG13_DENOM - RNG13_GUARD_MARGIN;

    if (remainder >= RNG13_HALF) {
        q0++;
        if (q0 == RNG13_BASE) {
            q0 = 0;
            q1++;
            if (q1 == RNG13_BASE) {
                q1 = 0;
                q2++;
                if (q2 == RNG13_BASE) {
                    q2 = 0;
                    q3++;
                }
            }
        }
    }

    rng13_candidate out;
    out.state = (rng13_state){q0, q1, q2, q3};
    out.remainder = remainder;
    out.safe = !(nearHalf || nearZeroWrap || nearTopWrap);
    return out;
}

inline rng13_state rng13_increment(rng13_state state) {
    state.d0++;
    if (state.d0 == RNG13_BASE) {
        state.d0 = 0;
        state.d1++;
        if (state.d1 == RNG13_BASE) {
            state.d1 = 0;
            state.d2++;
            if (state.d2 == RNG13_BASE) {
                state.d2 = 0;
                state.d3++;
            }
        }
    }
    return state;
}

inline rng13_state rng13_decrement(rng13_state state) {
    if (state.d0) {
        state.d0--;
    } else {
        state.d0 = RNG13_BASE - 1U;
        if (state.d1) {
            state.d1--;
        } else {
            state.d1 = RNG13_BASE - 1U;
            if (state.d2) {
                state.d2--;
            } else {
                state.d2 = RNG13_BASE - 1U;
                state.d3--;
            }
        }
    }
    return state;
}

inline rng13_state rng13_native_fallback(
    rng13_state state,
    rng13_state decimalState
) {
    ulong nativeK = rng13_native_next_k(rng13_to_double(state));
    ulong decimalK = rng13_to_ulong(decimalState);
    if (nativeK == decimalK) return decimalState;
    if (nativeK == RNG13_SCALE && decimalK == 0UL) {
        return (rng13_state){0U, 0U, 0U, 10U};
    }
    if (nativeK == 0UL && decimalK == RNG13_SCALE) {
        return (rng13_state){0U, 0U, 0U, 0U};
    }
    if (nativeK == decimalK + 1UL) return rng13_increment(decimalState);
    if (decimalK == nativeK + 1UL) return rng13_decrement(decimalState);

    // Defensive path if the analytical one-unit bound is ever violated. It is
    // intentionally slow but keeps the prototype exact rather than guessing.
    return rng13_from_ulong(nativeK);
}

inline rng13_step rng13_guarded_next(rng13_state state) {
    rng13_candidate candidate = rng13_decimal_candidate(state);
    rng13_step out;
    out.usedFastPath = candidate.safe;
    out.state = candidate.safe
        ? candidate.state
        : rng13_native_fallback(state, candidate.state);
    return out;
}

#endif
