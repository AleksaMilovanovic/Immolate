# fp64 -> 32-bit emulation, 2026-09-29

**Verdict: exact emulation works, and it does not pay on the RTX 5080.** Every conversion below is
bit-exact and verified. In real filters the gain is 0-2%, and sometimes a small loss. The prototype
code is reproduced in the appendices so nobody has to rebuild it. None of it is in `lib/`.

## Why not float-float (pairs of fp32)?

- **Too few bits.** Two floats carry 48 significand bits and fp64 has 53, so it is lossy.
- **Extra precision is also wrong.** The requirement is to round every multiply and add exactly
  where LuaJIT rounds (RNE to 53 bits, no FMA contraction). Triple-float or wider fixed point only
  works if each step is rounded to binary64 exactly.
- **Integer limbs are the natural fit.** On sm_120, FP32 and INT32 share the same 128 lanes/clk/SM,
  so "fp32 ops" and "int ops" spend one budget. The FP64 unit is separate (2 lanes/clk/SM, 1/64).

## What was converted, and how

1. **Node advance** (`rng_node_advance`, and ANN's own copy `ann_advance`):
   `s' = roundDigits(fract(s*1.72431234 + 2.134453429141), 13)`.
   - Keep the real fp64 `u = s*c1 + c2` (two roundings).
   - `u` is always in [2,4), so `fract(u) = F*2^-51` with `F = bits(u) & (2^51-1)`.
   - `fl(f*1e13)`: form `F*1e13` exactly in 128 bits (`mul_hi`), then RNE to 53 significant bits
     (`fi_rne53`).
   - `round()` is half away from zero, which for positive values is `(T + 2^(50-sh)) >> (51-sh)`.
   - Integer to double via clz (`fi_u53_scaled`), then the existing fp64 `div_1e13`.
   - `(x)/2` becomes an exponent decrement (`fi_half`).
   - Guard: fall back to fp64 if the exponent field of `u` is not 0x400 (inf/NaN state).
2. **`l_random`**: `x - 1.0` for x in [1,2) is exactly `R*2^-52`, where R is the mantissa bits.
3. **`l_randint`** (n < 2048): `fl(R*2^-52*n)` is `RNE53(R*n)*2^-52`, then truncate. `R*n` fits in
   a ulong.
4. **`randomseed`** (the Fable subagent's `randomseed_lean`), 4x `d=fl(d*pi); d=fl(d+e)`:
   - Carry the value as (T, E), T in [2^52, 2^53].
   - Product: 4x `mad.wide.u32` via inline PTX (NVIDIA OpenCL accepts `asm`).
   - Extraction: `shf.r.clamp` funnel shifts.
   - RNE decided in 32-bit.
   - Key trick: for d0 in [0,1), stages 2-4 have exponents fixed to within 1. The alignment of e
     is a compile-time constant picked by one compare, so there is no general clz or alignment.
   - Stage 1 handles d0's variable exponent.
   - `if (u<m) u+=m` is provably dead (u >= 2^62).
   - Inputs outside [0,1) use the fp64 state words but share one copy of the ten `_randint`
     warm-ups. A duplicated warm-up in a dead fallback branch cost as much as the entire emulation.
   - About 50 PTX per stage.

## Verification (all 0 mismatches)

- **Advance, `l_random`, `l_randint`:** about 1.9e10 comparisons against the fp64 expressions,
  over 1e8 seeds. Inputs were real advance chains plus s = 0 and s = 1 (k = 1e13 is reachable).
- **`randomseed_lean`:** 1.34e10 inputs per run. Inputs included real chains, random mantissas
  over 2^-40..1, exact product ties, subnormals, 0, 1-2^-53, and the fallback path.
- **Filters:** scores bit-identical for `erratic_flush_five` (16.7M seeds), `deep_negative_shops`
  (20k) and `analyze_naneinf_negatives` (2k-seed range plus 2 single seeds).
- **Verifier self-check:** every verifier was run with an injected one-bit error first, to prove
  it can fail.

## Measurements (200M seeds unless noted, uncontended GPU)

| kernel | native | exact emulation |
|---|---|---|
| `bench_hash_fp64` (hash + 51 advances) | 0.70s | 0.60s with the int advance (-15%) |
| `bench_rng_int` (52 randomseed) | 0.49s | ~0.43s lean (-10-15%); old generic softfloat (git `aedde58`) +15% |
| `erratic_flush_five` | 1.12s | advance 0%, int `l_randint` +3.5%, lean randomseed within noise |
| ANN single seed, `-g 1` (~12s) | - | advance +-0.5%, randomseed -2%, `l_random`/`l_randint` +1-2%, all three +1.5-2% |
| ANN `--group_per_seed` (0.7-2.4s) | - | all within -1% to +4% |

**Why 64x per instruction does not translate.** In real filters the FP64 unit runs alongside int
and local-memory work (Tausworthe warm-ups, the instance living in local memory). Emulation moves
work onto the lanes that are already the bottleneck. One exact fp64 op costs about 50 32-bit
instructions against about 64 native, which is too thin a margin once those lanes are busy.

## How to measure an fp64 ceiling (read this before trying again)

- **fp32 stand-in** (swap fp64 for fp32, wrong values). Only valid for fixed-work kernels. In any
  filter where draws change control flow (resamples, locks, ANN's branch tree) the fp32 build does
  different work.
- **Doubling** (run every fp64 op twice, OR the duplicate into the result under an all-ones-iff-NaN
  integer mask, so results stay bit-identical). This preserves control flow, but it greatly
  **overstates** the gain.
  - ANN doubled costs +49-60% (hash +15-24%, RNG path +35-38%), yet removing the RNG-path fp64
    entirely bought about 2%.
  - Queuing extra work on a busy FP64 unit is not the same as the kernel waiting on it.
- **Doubling pitfall:** an inline-asm `mov` "opaque copy" plus an empty `asm volatile` sink is
  removed by ptxas. The duplicate must feed the real result.
- **Other gotchas:**
  - The kernel binary cache does not hash files `#include`d from `diagnostics/`, so use
    `--no_cache`.
  - `--build_opts` takes one quoted string.
  - `half` is a reserved type name in OpenCL C.
  - A single-seed run is bound by that seed's own serial chain, and a range run with fewer seeds
    than lanes (43,008) is bound by its slowest seed.
  - Check `nvidia-smi` and `tasklist` for other Immolate runs. Contention gave 2-3x bimodal timings.

**Not tried:** an exact int `ph_step` (hash). The doubling split put the hash at about a third of
ANN's doubled fp64 cost, and the RNG path, which was fully converted, returned about 2%. Expect a
few percent at most.

## Appendix A: `lib/fp64_int.cl` (advance / l_random / l_randint helpers)

```c
// PROTOTYPE: exact integer replacements for fp64 instructions that are really
// bit manipulation. None of these rounds differently from the fp64 code it
// replaces; see diagnostics/zz_fp64_int_verify.cl.

// n * 2^-s as a double, exactly. Requires 0 <= n < 2^53 and a normal result.
inline double fi_u53_scaled(ulong n, int s) {
    if (n == 0) return 0.0;
    int p = 63 - (int)clz(n);                 // leading bit position, <= 52
    ulong m = n << (52 - p);
    return as_double(((ulong)(1023 + p - s) << 52) | (m & 0x000FFFFFFFFFFFFFUL));
}

// Round the 128-bit value hi:lo (bit length <= 117) to 53 significant bits,
// nearest-even, as an fp64 multiply would. Returns T and sh with the rounded
// value equal to T << sh; T <= 2^53.
inline ulong fi_rne53(ulong hi, ulong lo, int* sh_out) {
    int L = hi ? 128 - (int)clz(hi) : 64 - (int)clz(lo);
    int sh = L > 53 ? L - 53 : 0;
    ulong T, rem, hlf;
    if (sh == 0) {
        *sh_out = 0; return lo;
    } else if (sh < 64) {
        T = (lo >> sh) | (hi << (64 - sh));
        rem = lo & ((1UL << sh) - 1UL);
        hlf = 1UL << (sh - 1);
    } else {
        // Not reachable for the callers below (products < 2^95 give sh <= 42).
        *sh_out = sh; return 0;
    }
    if (rem > hlf || (rem == hlf && (T & 1UL))) T++;
    *sh_out = sh;
    return T;
}

// roundDigits(fract(u), 13) numerator for u in [2, 4): returns
// round(fl(fract(u) * 1e13)) as an integer. fract is exact there, the product
// F * 1e13 is formed exactly in 128 bits, rounded to 53 bits like the fp64
// multiply, then rounded half away from zero like round().
inline ulong fi_round13_fract_u(double u) {
    ulong F = as_ulong(u) & 0x0007FFFFFFFFFFFFUL;   // fract(u) = F * 2^-51
    const ulong D = 10000000000000UL;
    ulong lo = F * D, hi = mul_hi(F, D);
    int sh;
    ulong T = fi_rne53(hi, lo, &sh);                 // fl(f*1e13) = T * 2^(sh-51)
    // round half away (positive): floor(T*2^(sh-51) + 1/2), sh <= 42
    return (T + (1UL << (50 - sh))) >> (51 - sh);
}

// (x) * 0.5 for positive normal x with exponent field >= 2: exact.
inline double fi_half(double x) {
    ulong b = as_ulong(x);
    return (b >= (2UL << 52)) ? as_double(b - (1UL << 52)) : x * 0.5;
}
```

Call sites, as they were wired (behind `#ifdef FP64_INT`):

```diff
diff --git a/lib/immolate.cl b/lib/immolate.cl
index e77c62f..e10435d 100644
--- a/lib/immolate.cl
+++ b/lib/immolate.cl
@@ -16,6 +16,7 @@
     #define VER4 6 //1.0.1f
     #define GAME_VERSION
 #endif
+#include "lib/fp64_int.cl" // PROTOTYPE exact int replacements
 #include "lib/util.cl" // Contains utility functions
 #include "lib/seed.cl" // Contains seed/seed list info
 #include "lib/items.cl" // Contains item enums, lists, helper functions
diff --git a/lib/instance.cl b/lib/instance.cl
index 79049b2..6d0d58c 100644
--- a/lib/instance.cl
+++ b/lib/instance.cl
@@ -5,6 +5,17 @@
 // the deck path (init_deck / get_deck / anything reading params.deckCards); such
 // a filter would fail to compile rather than read a missing array, so the switch
 // cannot silently change results. Undefined by default: layout is unchanged.
+// RS_SEED is the LuaJIT randomseed entry used by every RNG call below. It is
+// randomseed() from util.cl unless RS_LEAN is defined, in which case it is
+// randomseed_lean() (PROTOTYPE: fp64-free bit-exact version, defined later in
+// diagnostics/zz_rs_lean.cl by the wrapper kernel that defines RS_LEAN).
+// Undefined by default: behaviour is unchanged.
+#ifdef RS_LEAN
+lrandom randomseed_lean(double d);
+#define RS_SEED randomseed_lean
+#else
+#define RS_SEED randomseed
+#endif
 typedef struct InstanceParameters {
     item deck;
     item stake;
@@ -149,19 +160,29 @@ rng_node_id rng_node_resolve(instance* inst, ntype nts[], int ids[], int num) {
 }
 inline double rng_node_advance(instance* inst, rng_node_id node_id) {
     inst->rngCache.lastNode = (short)node_id;
+#if defined(FP64_INT) || defined(FP64_INT_ADV)
+    double u = inst->rngCache.nodes[node_id].rngState*1.72431234+2.134453429141;
+    if ((as_ulong(u) >> 52) == 0x400) { // u in [2,4): always, unless the state is inf/NaN
+        inst->rngCache.nodes[node_id].rngState = div_1e13(fi_u53_scaled(fi_round13_fract_u(u), 0));
+    } else {
+        inst->rngCache.nodes[node_id].rngState = roundDigits(fract(u),13);
+    }
+    return fi_half(inst->rngCache.nodes[node_id].rngState + inst->hashedSeed);
+#else
     inst->rngCache.nodes[node_id].rngState = roundDigits(fract(inst->rngCache.nodes[node_id].rngState*1.72431234+2.134453429141),13);
     return (inst->rngCache.nodes[node_id].rngState + inst->hashedSeed)/2;
+#endif
 }
 inline double get_node_child(instance* inst, ntype nts[], int ids[], int num) {
     return rng_node_advance(inst, rng_node_resolve(inst, nts, ids, num));
 }
 inline double random_bound(instance* inst, rng_node_id node_id) {
-    inst->rng = randomseed(rng_node_advance(inst, node_id));
+    inst->rng = RS_SEED(rng_node_advance(inst, node_id));
     return l_random(&(inst->rng));
 }
 double random(instance* inst, ntype nts[], int ids[], int num) {
     if (num > 0) {
-        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
+        inst->rng = RS_SEED(get_node_child(inst, nts, ids, num));
     }
     return l_random(&(inst->rng));
 }
@@ -170,14 +191,14 @@ double random_simple(instance* inst, rtype rt) {
 }
 ulong randint(instance* inst, ntype nts[], int ids[], int num, ulong min, ulong max) {
     if (num > 0) {
-        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
+        inst->rng = RS_SEED(get_node_child(inst, nts, ids, num));
     }
     return l_randint(&(inst->rng), min, max);
 }
 
 item randchoice(instance* inst, ntype nts[], int ids[], int num, __constant item items[]) {//, size_t item_size) { not needed, we'll have element 1 give us the size
     if (num > 0) {
-        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
+        inst->rng = RS_SEED(get_node_child(inst, nts, ids, num));
     }
     return items[l_randint(&(inst->rng), 1, items[0])];
 }
@@ -206,7 +227,7 @@ item randchoice_simple(instance* inst, rtype rngType, __constant item items[]) {
 // Implementation specifically for dynamic arrays (Poker hands for Orbital Tag)
 item randchoice_dynamic(instance* inst, ntype nts[], int ids[], int num, item items[]) {//, size_t item_size) { not needed, we'll have element 1 give us the size
     if (num > 0) {
-        inst->rng = randomseed(get_node_child(inst, nts, ids, num));
+        inst->rng = RS_SEED(get_node_child(inst, nts, ids, num));
     }
     return items[l_randint(&(inst->rng), 1, items[0])];
 }
diff --git a/lib/util.cl b/lib/util.cl
index 0c7b69c..b81c8f3 100644
--- a/lib/util.cl
+++ b/lib/util.cl
@@ -242,10 +242,27 @@ lrandom randomseed(double d) {
 }
 double l_random(lrandom* lr) {
     randdblmem(lr);
+#if defined(FP64_INT) || defined(FP64_INT_RNG)
+    // x in [1,2) with mantissa R: x - 1.0 == R * 2^-52 exactly.
+    lr->out.d = fi_u53_scaled(lr->out.ul & 0x000FFFFFFFFFFFFFUL, 52);
+#else
     lr->out.d -= 1.0;
+#endif
     return lr->out.d;
 }
 ulong l_randint(lrandom* lr, ulong min, ulong max) {
+#if defined(FP64_INT) || defined(FP64_INT_RNG)
+    ulong n = max - min + 1;
+    if (n < 2048) {
+        // d = R * 2^-52 exactly; fl(d*n) = RNE53(R*n) * 2^-52, then trunc.
+        randdblmem(lr);
+        ulong R = lr->out.ul & 0x000FFFFFFFFFFFFFUL;
+        lr->out.d = fi_u53_scaled(R, 52);
+        int sh;
+        ulong T = fi_rne53(0, R * n, &sh);
+        return (T >> (52 - sh)) + min;
+    }
+#endif
     l_random(lr);
     return (ulong)(lr->out.d*(max-min+1))+min;
 }
```

## Appendix B: `randomseed_lean` (Fable subagent, bit-exact, RSL_MUL=3 fastest)

```c
// PROTOTYPE: fp64-free, bit-exact randomseed(double) for d in [0, 1).
// Include after "lib/immolate.cl".
//
// randomseed does d = fl(d*pi); d = fl(d+e) four times (FP_CONTRACT OFF, two
// RNE roundings per stage). This computes the same thing on 32/64-bit integers.
//
// Representation: a value is (T, E), value = T * 2^(E-52), T in [2^52, 2^53].
// T == 2^53 (a rounding carry) is allowed and stays consistent: the multiply
// then gives a 106-bit product with k = 1, and the packed state word
// ((E+1022) << 52) + T carries the 2^53 into the exponent field by itself.
//
// Per stage:
//  1. P = T * Mpi exactly, 105 or 106 bits, k = bit 105. fl(d*pi) = RNE(P >> (52+k))
//     = trunc + up, unit 2^(a-51), a = E + k. Round-up test on the dropped bits,
//     done in 32-bit: (remH | (w0 != 0)) + (trunc&1) > 2^(19+k), where remH is
//     the dropped part of product word 1. OR-ing the sticky into bit 0 of remH
//     is exact because the half point 2^(19+k) is even.
//  2. Add e = Me * 2^-51 and round once more:
//     - stages 2..4: fl(d*pi) >= 8.5 > e, so e is the one being shifted, by a,
//       and for d0 in [0,1) a takes exactly two values per stage (interval
//       table in randomseed_lean, checked by zz_rs_lean_verify). So e's integer
//       part eT = Me >> a and its fraction f = (Me mod 2^a) / 2^a are
//       compile-time constants (f is never 0 or 1/2 for a in 2..6).
//       V = trunc + up + eT. If V < 2^53 (c = 0): result = V + (f > 1/2). Else
//       (c = 1) one more bit is dropped: fraction ((V&1) + f)/2 is > 1/2 iff V
//       odd, so result = (V+1) >> 1. Both: result = (V + x) >> c, x = c | (f > 1/2).
//     - stage 1: fl(d*pi) < 4, e's binade or below, so T' is shifted right by
//       s = -a with remainder rem. V = Me + (T' >> s). If c = 0:
//       round up iff 2*rem + (V&1) > 2^s (rem > half, or == half and V odd).
//       If c = 1 (only possible for s <= 1, so rem is just the guard bit):
//       result = (V >> 1) + ((V&1) & ((rem | (V>>1)) & 1)) = (V + 2*up1) >> 1.
//       d = 0 and subnormals need no special case: s is clamped to 55, which
//       shifts T' to 0 with a remainder below half.
//  3. E'' = (exponent of the larger addend) + 1 + c; state word as above.
//     The original `if (u < m) u += m` is provably false (u >= 2^62, m <= 2^17)
//     and is omitted.
// Inputs outside [0, 1) (negative, >= 1, NaN) take randomseed()'s fp64 path for
// the four state words; both paths share one copy of the ten warm-up steps.
//
// RSL_MUL selects how the 53x53-bit product is formed (timing experiments):
//   0: (ulong)uint * uint products (NVVM emits mul.lo.s64; ptxas may narrow)
//   1: 32-bit mul_hi / mul pairs (mul.hi.u32 + mul.lo.u32)
//   2: ulong mul + mul_hi(ulong) and let the compiler split it
//   3: inline PTX: mul/mad.wide.u32 for the product, shf.r.clamp.b32 funnel
//      shifts for the extraction and the final >> c (NVIDIA only). Fastest
//      measured on the RTX 5080; 0 is portable and within noise of it.
// All variants are bit-exact (zz_rs_lean_verify, 1e8 seeds x 134 inputs each).
// RSL_ABL_NOMUL / NOADD / NOFB / SKEL are timing-only ablations (wrong values).

#ifndef RSL_MUL
#define RSL_MUL 0
#endif

#define RSL_MPI 0x001921FB54442D18UL   // pi = RSL_MPI * 2^-51 (implicit bit included)
#define RSL_ME  0x0015BF0A8B145769UL   // e  = RSL_ME  * 2^-51
// (Me mod 2^a) / 2^a > 1/2 ?  (never == 1/2 for a in 2..6: low bits of Me are 101001)
#define RSL_FUP(a) ((uint)((RSL_ME & ((1UL << (a)) - 1UL)) > (1UL << ((a) - 1))))

// fl(T * pi) = trunc + up, both returned; sets k = bit 105 of the product.
// trunc has 53 bits (or is 2^53 - 1 with up = 1).
inline ulong rsl_mulpi(ulong M, int* k, uint* up) {
#ifdef RSL_ABL_NOMUL   // timing ablation: no product, wrong values
    *k = (int)M & 1; *up = (uint)(M >> 1) & 1u; return (M ^ (M >> 3)) & 0x001FFFFFFFFFFFFFUL;
#endif
    uint a0 = (uint)M, a1 = (uint)(M >> 32);          // a1 < 2^22
    const uint b0 = (uint)RSL_MPI, b1 = (uint)(RSL_MPI >> 32);
    uint w0, w1;       // product bits 0..31, 32..63
    ulong hi;          // product >> 64, < 2^42
#if RSL_MUL == 1
    w0 = a0 * b0;
    ulong mid = (ulong)mul_hi(a0, b0) + a0 * b1 + a1 * b0;             // low words
    ulong mid_hi = (ulong)mul_hi(a0, b1) + mul_hi(a1, b0);             // < 2^23
    w1 = (uint)mid;
    hi = ((ulong)(a1 * b1) | ((ulong)mul_hi(a1, b1) << 32)) + mid_hi + (mid >> 32);
#elif RSL_MUL == 3
    ulong p00, mid;
    asm("mul.wide.u32 %0, %1, %2;" : "=l"(p00) : "r"(a0), "r"(b0));
    asm("mad.wide.u32 %0, %1, %2, %3;" : "=l"(mid) : "r"(a0), "r"(b1), "l"(p00 >> 32));
    asm("mad.wide.u32 %0, %1, %2, %3;" : "=l"(mid) : "r"(a1), "r"(b0), "l"(mid));
    asm("mad.wide.u32 %0, %1, %2, %3;" : "=l"(hi) : "r"(a1), "r"(b1), "l"(mid >> 32));
    w1 = (uint)mid;
    w0 = (uint)p00;
#elif RSL_MUL == 2
    ulong lo = M * RSL_MPI;
    hi = mul_hi(M, RSL_MPI);
    w0 = (uint)lo; w1 = (uint)(lo >> 32);
#else
    ulong p00 = (ulong)a0 * b0;
    ulong mid = (ulong)a0 * b1 + (p00 >> 32);
    mid += (ulong)a1 * b0;                             // < 2^54 + 2^32: no overflow
    hi = (ulong)a1 * b1 + (mid >> 32);
    w1 = (uint)mid;
    w0 = (uint)p00;
#endif
    int kk = (int)(hi >> 41) & 1;
    int sh = 20 + kk;
    // trunc = product >> (52+k): low word is the funnel (hi_lo:w1) >> sh, high word hi >> sh
#if RSL_MUL == 3
    uint t_lo, t_hi, h_lo = (uint)hi, h_hi = (uint)(hi >> 32);
    asm("shf.r.clamp.b32 %0, %1, %2, %3;" : "=r"(t_lo) : "r"(w1), "r"(h_lo), "r"(sh));
    asm("shf.r.clamp.b32 %0, %1, %2, %3;" : "=r"(t_hi) : "r"(h_lo), "r"(h_hi), "r"(sh));
#else
    uint t_lo = (uint)((((ulong)(uint)hi << 32) | w1) >> sh);
    uint t_hi = (uint)(hi >> sh);
#endif
    uint maskK = kk ? 0x1FFFFFu : 0x0FFFFFu;
    uint hlfK  = kk ? 0x100000u : 0x080000u;
    uint remH = (w1 & maskK) | min(w0, 1u);
    *up = (remH + (t_lo & 1u)) > hlfK;
    *k = kk;
    return ((ulong)t_hi << 32) | t_lo;
}

// Stage 1: bits = as_ulong(d), d in [0, 1). Returns T, sets E (1 or 2).
inline ulong rsl_stage1(ulong bits, int* E1) {
    ulong M = (bits & 0x000FFFFFFFFFFFFFUL) | 0x0010000000000000UL;
    int ef = (int)(bits >> 52);                        // biased exponent field <= 1022
    int k; uint up;
    ulong T = rsl_mulpi(M, &k, &up) + up;
    int s = min(1023 - ef - k, 55);                    // -a >= 0
    ulong R = T >> s;
    ulong rem = T - (R << s);
    ulong V = RSL_ME + R;
    int c = (int)(V >> 53) & 1;
    ulong up0 = (ulong)((2UL * rem + (V & 1UL)) > (1UL << s));
    ulong up1x2 = ((V & (rem | (V >> 1))) & 1UL) << 1;
    *E1 = 1 + c;
    return (V + (c ? up1x2 : up0)) >> c;
}

// Stages 2..4: a = E + k is aLo or aLo+1.
inline ulong rsl_stageN(ulong M, int E, int aLo, int* En) {
    int k; uint up;
    ulong trunc = rsl_mulpi(M, &k, &up);
    int a = E + k;
#ifdef RSL_ABL_NOADD   // timing ablation: skip the e add/round, wrong values
    *En = a + 1; return trunc + up;
#endif
    bool hiA = a != aLo;
    ulong eT  = hiA ? (RSL_ME >> (aLo + 1)) : (RSL_ME >> aLo);
    uint rup  = hiA ? RSL_FUP(aLo + 1) : RSL_FUP(aLo);
    ulong V = trunc + eT + up;
    int c = (int)(V >> 53) & 1;
    *En = a + 1 + c;
    V += (ulong)(rup | (uint)c);
#if RSL_MUL == 3
    uint v_lo = (uint)V, v_hi = (uint)(V >> 32), r_lo;
    asm("shf.r.clamp.b32 %0, %1, %2, %3;" : "=r"(r_lo) : "r"(v_lo), "r"(v_hi), "r"((uint)c));
    return ((ulong)(v_hi >> c) << 32) | r_lo;
#else
    return V >> c;
#endif
}

#define RSL_PACK(T, E) (((ulong)((E) + 1022) << 52) + (T))

lrandom randomseed_lean(double d) {
    lrandom lr;
    ulong b = as_ulong(d);
#ifndef RSL_ABL_NOFB   // timing ablation: no fp64 fallback branch
    if (b >= 0x3FF0000000000000UL) {
        // d < 0, d >= 1, NaN: the fp64 path of randomseed(), state words only.
        // It converges onto the shared warm-up loop below instead of calling
        // randomseed(): a second copy of the ten _randint steps in a dead
        // branch measured as costly as the whole emulation (bench_rng_int).
        uint r = 0x11090601;
        for (int i = 0; i < 4; i++) {
            uint m = 1 << (r & 255);
            r >>= 8;
            d = d * 3.14159265358979323846;
            d = d + 2.7182818284590452354;
            ulong u = as_ulong(d);
            if (u < m) u += m;
            lr.state[i] = u;
        }
    } else
#endif
    {
        int E;
        // For d0 in [0,1):     value range      E (unbiased)   product exponent   a = E+k
        // d1 = fl(fl(d0*pi)+e) [2.718, 5.86)    1,2            <= 1               <= 0 (stage 1)
        // d2                   [11.26, 21.14)   3,4            3,4                2,3
        // d3                   [38.1, 69.2)     5,6            5,6                4,5
        // d4                   [122, 220)       6,7            6,7                5,6
#ifdef RSL_ABL_SKEL    // timing ablation: trivial stages, wrong values
        ulong T = b ^ (b >> 3); E = 1;
        lr.state[0] = RSL_PACK(T, E); T ^= T >> 5; E = 3;
        lr.state[1] = RSL_PACK(T, E); T ^= T >> 7; E = 5;
        lr.state[2] = RSL_PACK(T, E); T ^= T >> 9; E = 6;
        lr.state[3] = RSL_PACK(T, E);
#else
        ulong T = rsl_stage1(b, &E);
        lr.state[0] = RSL_PACK(T, E);
        T = rsl_stageN(T, E, 2, &E);
        lr.state[1] = RSL_PACK(T, E);
        T = rsl_stageN(T, E, 4, &E);
        lr.state[2] = RSL_PACK(T, E);
        T = rsl_stageN(T, E, 5, &E);
        lr.state[3] = RSL_PACK(T, E);
#endif
    }
    for (int i = 0; i < 10; i++) _randint(&lr);
    return lr;
}
```

## Appendix C: verifier kernels

```c
#define FP64_INT
#include "lib/immolate.cl"
// Score = number of mismatches between the exact-int prototype and the
// original fp64 expressions. Any seed printed with -c 1 is a failure.
double ref_adv(double s) { return roundDigits(fract(s*1.72431234+2.134453429141),13); }
double new_adv(double s) {
    double u = s*1.72431234+2.134453429141;
    return div_1e13(fi_u53_scaled(fi_round13_fract_u(u), 0));
}
long filter(instance* inst) {
    long bad = 0;
    double H = inst->hashedSeed;
    // 1) node advance: walk a real chain from this seed's hash, plus raw inputs
    double s = H;
    for (int i = 0; i < 64; i++) {
        double a = ref_adv(s), b = new_adv(s);
        bad += as_ulong(a) != as_ulong(b);
        bad += as_ulong((a + H)/2) != as_ulong(fi_half(a + H));
        s = a;
    }
    // edges: s = 0, 1, and values next to 1
    bad += as_ulong(ref_adv(0.0)) != as_ulong(new_adv(0.0));
    bad += as_ulong(ref_adv(1.0)) != as_ulong(new_adv(1.0));
    // 2) l_random / l_randint on real LuaJIT streams
    lrandom a = randomseed(H), b = a;
    for (int i = 0; i < 32; i++) {
        ulong n = 1 + (i * 37 + (as_ulong(H) & 1023)) % 2047;
        randdblmem(&a);
        double da = a.out.d - 1.0;
        ulong ra = (ulong)(da * (double)n);
        ulong rb = l_randint(&b, 1, n) - 1;
        bad += ra != rb;
        bad += as_ulong(da) != as_ulong(b.out.d);
    }
    return bad;
}
```

```c
#include "lib/immolate.cl"
#include "diagnostics/zz_rs_lean.cl"
// impl version: v5 (cache key includes this file but not zz_rs_lean.cl; bump on change)
// Score = number of mismatching state words between randomseed_lean and the
// fp64 randomseed over RSLV_N inputs per seed. Any printed seed is a failure.
// Build with -D RSL_INJECT to flip one bit of one lean result (verifier check).

inline ulong rslv_next(ulong* x) { // splitmix64
    ulong z = (*x += 0x9E3779B97F4A7C15UL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
    return z ^ (z >> 31);
}

inline long rslv_cmp(double x, int inject) {
    lrandom a = randomseed(x), b = randomseed_lean(x);
#ifdef RSL_INJECT
    if (inject) b.state[2] ^= 1UL << 7;
#endif
    long bad = 0;
    for (int j = 0; j < 4; j++) bad += a.state[j] != b.state[j];
    return bad;
}

long filter(instance* inst) {
    long bad = 0;
    double H = inst->hashedSeed;
    ulong x = as_ulong(H);
    // 1. real chains: node states advanced like rng_node_advance, d = (s+H)/2
    double s = fract(H * 1.7 + 0.3);
    for (int i = 0; i < 24; i++) {
        s = roundDigits(fract(s * 1.72431234 + 2.134453429141), 13);
        bad += rslv_cmp((s + H) / 2, i == 5);
    }
    // 2. random 52-bit mantissas, exponents 2^-40 .. 2^-1
    for (int i = 0; i < 40; i++) {
        ulong r = rslv_next(&x);
        int e = 1022 - (int)(r % 40);            // biased exp for [2^-40, 1)
        ulong bits = ((ulong)e << 52) | (rslv_next(&x) & 0x000FFFFFFFFFFFFFUL);
        bad += rslv_cmp(as_double(bits), 0);
    }
    // 3. multiply ties: M = 2^48 mod 2^49 (k=0 tie) and 2^49 mod 2^50 (k=1 tie)
    for (int i = 0; i < 16; i++) {
        ulong r = rslv_next(&x);
        int e = 1022 - (int)(r % 8);
        ulong m = (rslv_next(&x) << 49) | (1UL << 48);
        bad += rslv_cmp(as_double(((ulong)e << 52) | (m & 0x000FFFFFFFFFFFFFUL)), 0);
        m = (rslv_next(&x) << 50) | (1UL << 49);
        bad += rslv_cmp(as_double(((ulong)e << 52) | (m & 0x000FFFFFFFFFFFFFUL)), 0);
    }
    // 4. sparse mantissas (few trailing bits) at varied exponents: add-stage ties
    for (int i = 0; i < 16; i++) {
        ulong r = rslv_next(&x);
        int e = 1022 - (int)(r % 24);
        int z = (int)((r >> 8) % 52);
        ulong m = (rslv_next(&x) >> z) << z;
        bad += rslv_cmp(as_double(((ulong)e << 52) | (m & 0x000FFFFFFFFFFFFFUL)), 0);
    }
    // 5. specials
    bad += rslv_cmp(0.0, 0);
    bad += rslv_cmp(as_double(0x3FEFFFFFFFFFFFFFUL), 0);   // largest below 1
    bad += rslv_cmp(as_double(0x3FEFFFFFFFFFFFFEUL), 0);
    bad += rslv_cmp(0.5, 0);
    bad += rslv_cmp(0.25, 0);
    bad += rslv_cmp(as_double(0x3FE0000000000001UL), 0);
    bad += rslv_cmp(as_double(1UL), 0);                    // smallest subnormal
    bad += rslv_cmp(as_double(0x000FFFFFFFFFFFFFUL), 0);   // largest subnormal
    bad += rslv_cmp(as_double(0x0010000000000000UL), 0);   // smallest normal
    bad += rslv_cmp(as_double(0x3C00000000000000UL), 0);   // 2^-63
    bad += rslv_cmp(as_double(0x3BF0000000000000UL), 0);   // 2^-64
    bad += rslv_cmp(as_double(0x3BE0000000000000UL), 0);   // 2^-65
    bad += rslv_cmp(as_double(0x3E00000000000000UL), 0);   // 2^-31
    bad += rslv_cmp(as_double(0x3DF0000000000000UL), 0);   // 2^-32
    bad += rslv_cmp(as_double(((ulong)(1022 - (int)(x % 1000)) << 52) | (x >> 12)), 0); // tiny
    bad += rslv_cmp(1.0, 0);                               // fallback path
    bad += rslv_cmp(-0.5, 0);                              // fallback path
    bad += rslv_cmp(H, 0);
    return bad;
}
```
