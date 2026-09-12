# Diagnostic suite — what to run on the RTX 5080

Four independent analyses agree on the per-seed work profile (~52,800 RNG draws, 94% of them on the
filter's scalar streams) but **not** on what the kernel is bound by. The competing models predict
opposite results on specific fixtures. This suite exists to settle that with measurement.

Everything named `diag_*` **produces deliberately wrong scores** — these are ablations for cost
attribution, not correctness artefacts. None is referenced by `tests/golden/`, and none may ever be.
The two exceptions are `diag_rng_a6_exact` and `dns_staged_resample*`, which were verified
score-identical to their baselines and are the only adoptable fixtures here.

---

## Step 0 — calibrate (about a minute)

Seed counts in `tests/diagnostics.json` assume the 5080 launch width of **43,008 lanes**
(84 CU x 16 groups x 32) and give every lane 10 seeds. Whether that is 5 s or 60 s per run depends on
throughput nobody here has measured. Find out first:

```bash
python3 tests/dispatch_bench.py calibrate --target 10
```

The executable and the device's compute-unit count are discovered automatically; pass `--exe` / `--cu`
only to override them. It prints a calibrated `-n` and the probe time.

Measured on the target 5080: **344,064 seeds in 32.24 s, i.e. ~10,800 seeds/s.** The calibrated count
clamped to the saturation floor (8 x 43,008 lanes), and `tests/diagnostics.json` is sized to match, so
one heavy case is 1 warm-up + 3 samples ~ 2.2 min. Budget **~21 min for `diag-stage1`** and **~95 min
for `diag-all`** -- run stage 1 first and let its result decide whether the rest is worth the wall time.
`--repeat 2` trims stage 1 to ~16 min; the effects it looks for (0.79, 1.199, 0.86) are far outside
run-to-run noise, so two samples suffice.

---

## Step 1 — the register/spill log (free, no benchmark)

Three of the four analyses independently named this the cheapest missing datum in the investigation.

```bash
./build/Immolate -f deep_negative_shops --verbose_build -n 1 -g 1 2>&1 | tee d0-verbose-build.txt
```

On Windows: `.\build\Release\Immolate.exe -f deep_negative_shops --verbose_build -n 1 -g 1 > d0-verbose-build.txt 2>&1`

**Run this before Step 2.** It costs about a second and it decides how Step 2 is read.

**Send me `d0-verbose-build.txt`.** What it settles, from the `search` / `search_ranks` entries:

| registers/thread | warps resident | consequence |
|---|---|---|
| <=128 | >=16 | launch geometry already fine; the `-g` candidate is worth ~1.00x |
| **129-136** | **15** | **the pathological case: `-g` worth ~1.78x, `-cl-nv-maxrregcount` worth ~1.88x** |
| 137-144 | 14 | `-g` worth ~1.75x |
| 145-168 | 12-13 | `-g` worth ~1.45x |
| >=200 | <=8 | register pressure is the problem; fix that before anything else |

Non-zero **spill stores/loads** rejects the `maxrregcount` candidate and reframes the rest.
Local memory per thread should read ~5,056 B for DNS at `CACHE_SIZE 256`.

---

## Step 2 — the three decisive experiments (~10 cases)

```bash
python3 tests/run.py --profile diag-stage1 --scale rtx5080
```

Each of these separates two models that predict opposite things.

**A. Ballast sweep** (`mem-ballast-{0k,1k,2k,4k,8k}`) — unused-but-unremovable padding in `instance`.
Same draws, same ALU, same memory traffic; **only the per-work-item footprint changes**, and scores stay
bit-identical.
- **flat (~1.000)** -> occupancy/capacity is not the binding constraint; all footprint work is dead
- **1.023 / 1.047 / 1.095 / 1.199** -> allocation-slope model holds at ~2.3%/KB

> **Mandatory sanity gate.** In the `--verbose_build` output, `ballast8k`'s stack frame must exceed
> `ballast0`'s by ~8,192 B. If it does not, the compiler eliminated the array and the experiment
> measured nothing. Check this before believing a flat result.

**B. `dns-cand-staged128`** — depth-major resample restructure. **Zero draw-count change**: identical
arithmetic, identical RNG, identical everything except lane scheduling. Any movement at all is divergence.
- **~0.79** -> loop-level divergence is real; the restructure is worth 1.264x
- **~1.00** -> it is not (and it costs ~3% on CPU devices, so it would be dropped)

**C. `diag-a6-exact`** — the bit-exact fp64 strength-reduction bundle, verified over 18,000 seeds
(~900M draws). Predicted **0.86-0.90** (1.11-1.16x). This one depends on no unresolved model; if it
lands there it is adoptable as-is.

---

## Step 3 — the `-g` sweep (no code change, just the flag)

The largest single lead. `immolate.c` launches `computeUnits * 16` work-groups; with 15 warps resident
per SM that is `ceil(16/15) = 2` waves for `16/15` waves of work — a **1.875x** makespan penalty.

```bash
python3 tests/dispatch_bench.py g-sweep --target 10
```

- **sawtooth, jumping at k >= 32** -> wave quantization; adopt the best k (worth up to 1.82x)
- **monotone decline past k ~ 11-18** -> L2 residency cliff; **leave `-g` alone**, raising it is harmful
- **flat** -> launch geometry is not the constraint; both `-g` and `maxrregcount` are dead

---

## Step 4 — attribution ladders (optional, gives the ceilings)

```bash
python3 tests/run.py --profile diag-rng --scale rtx5080     # RNG component ablations + ILP chain probe
python3 tests/run.py --profile diag-dns --scale rtx5080     # per-stream ablations
python3 tests/run.py --profile diag-mem --scale rtx5080     # CACHE_SIZE sweep + composite footprint
```

For any ablation, the hard ceiling on optimizing that component is `bound = (1 - ratio) / 0.941`.
So a fixture returning 0.95 means **nothing you do to that component can ever buy more than ~5.3%.**

Fixtures where the two models predict *opposite* orderings, i.e. the ones actually worth reading:

| case | ALU model | divergence model |
|---|---|---|
| `dns-abl-uncid` | 0.903 | **0.751** |
| `dns-probe-nolocks` | 0.951 | **0.729** |
| `dns-probe-maxframes` (8% *more* work) | **1.080** | 0.996 |
| `dns-cand-staged128` (zero draw change) | ~1.000 | **0.791** |

`diag-chain-k{1,2,4,8}` settles latency- vs throughput-bound: time-per-chain **falling with K** means
latency-bound; **flat from K=1** means throughput-bound, which is what the arithmetic predicts.

`diag-a3-intstate` bounds the `rng_advance_int` revert, which per `git log` was **never benchmarked
end-to-end** — only two microbenchmark fixtures, no `test-results/` entry.

---

## What to send back

1. the calibration line from Step 0
2. `d0-verbose-build.txt`
3. the `[RATIO]` block printed at the end of each `tests/run.py` run
4. the sweep table from `dispatch_bench.py g-sweep`

The results directory path is printed at the end of every run; `test-results/<run>/summary.txt` has the
same ratios if it is easier to attach.

---

## Defects fixed while folding this in

- **Benchmark under-saturation.** `tests/cases.json` ran both deep-shop benchmarks at 2,048 seeds
  against a 43,008-lane launch — **4.8% lane utilisation**, so wall clock measured the slowest single
  seed rather than throughput (measured distortion: 3.3x on PoCL, projected ~20x on a 5080). All
  benchmark counts are now whole multiples of the launch width. The three incoming diagnostic packs had
  the same defect (2,048-32,768) and were re-sized the same way.
- **`benchmark_repeats: 1` on the `pocl` scale**, so a "median" was a single sample and any local A/B was
  unfalsifiable. Now 5.
- **`Done in Xs` reported CPU time, not wall time.** `clock()` sums across threads: a 1.710 s run printed
  6.750 s (13.7x on an 18-core PoCL device, measured). On a GPU it happened to track wall time because
  the host spins in `clFinish` — so the same number meant two different things depending on device. Now
  prints `Done in <wall>s (cpu <cpu>s)`, and `tests/common.py`'s host-line filter was updated to match.
- **The `--from` path had no work-group-size fallback.** `immolate.c` called `clEnqueueNDRangeKernel`
  directly for the ranks kernel — the only launch in the program bypassing `enqueue_1d`, so a driver
  rejecting the local size there was a hard failure instead of a halve-and-retry. This is exactly DNS's
  documented workflow. Now routed through the shared helper.
- **`--count-scale`** added to `tests/run.py` so runtime can be traded against precision without editing
  the cases file.
- **`tests/dispatch_bench.py` had POSIX-only defaults** -- `./build/Immolate` (no `.exe`, wrong directory
  on a CMake/MSVC build) and `/tmp/immolate-dispatch`. It now finds the executable the way
  `tests/run.py` does, reads compute units from `--list_devices`, and uses `tempfile.gettempdir()`.

---

## Open questions (what the suite is for now)

Both wins above are landed. Two questions remain, one command each.

### Staging chunk size

`DNS_CHUNK` in `filters/deep_negative_shops.cl` is 128. The mask is now `DNS_CHUNK/64`
words, so any multiple of 64 works. The divergence model *under-predicted* chunk-128 by
1.6x (it said 1.264x, hardware gave 2.076x), so the curve may not have flattened.

```bash
python tests/run.py --profile diag-chunk --scale rtx5080
```

Compares 64 / 256 / 512 against the shipped 128. All four are bit-exact (verified over
20,000 seeds), so only the ratios matter. If 256 or 512 beats 1.000x, change the one
`#define`. ~5 min.

### The fp64 strength-reduction bundle

`diag_rng_a6_exact` measured only 1.029x against a predicted 1.11-1.16x -- but that run
predates the register cap, so it was contaminated by the allocation lottery. Now that the
build pins registers on NVIDIA, both sides of the comparison sit at 16 resident warps.

```bash
python tests/run.py --profile diag-rng --scale rtx5080
```

Read `diag-a6-exact / diag-a0-base`. ~9 min.

Two caveats. The a6 fixtures are built on the *pre-staging* DNS body, so this measures the
bundle against the old filter; the four transforms would need porting into the shipped
filter to be adopted. And the whole RNG core is capped at 19.7% on that old base -- against
the new one, which is 2.8x faster, the RNG core is a larger share of what remains, so a
positive result here is worth more than it looks.

---

# DNS factor-isolation suite

30 fixtures that separate every major cost factor in `deep_negative_shops`, built against the
**current** filter (depth-major staging, `DNS_CHUNK 512`). ~16 min on an RTX 5080.

```bash
python tests/run.py --profile diag-factors --scale rtx5080
```

On NVIDIA the build applies `-cl-nv-maxrregcount=128` automatically, so every case is
register-pinned without passing anything. That matters: unpinned, an earlier run's ratios were
dominated by a register-allocation lottery worth up to 12%, which is larger than most of the
effects being measured.

## Read it in this order

**1. `ctl-b / ctl-a` must be 1.000x +/- 0.5%.** A byte-identical pair. If it is not 1.000,
allocation is not controlled and **no other ratio in the run is readable** -- stop and say so.
This check is the single most important line in the output; its absence invalidated a previous run.

**2. `sub-tags` must be 0.99-1.00.** It removes 72 of ~52,300 draws (0.14%). A drop beyond ~2%
means the harness is measuring noise, not the fixtures.

**3. Subtractive family (`sub-*`)** -- ceiling per factor: the most that eliminating it could
ever save. Compare each against its draw share; a ratio far *below* its draw share prices
divergence, not work.

| stream | draws/seed | share |
|---|---:|---:|
| cardtype | 18,624 | 35.6% |
| rarity | 13,293 | 25.4% |
| edition | 13,293 | 25.4% |
| uncid base / resample | 3,333 / 1,739 | 6.4% / 3.3% |
| rareid base / resample | 662 / 807 | 1.3% / 1.5% |
| packsel / packcontents | 216 / 170 | 0.4% / 0.3% |
| vouchers | 115 | 0.22% |
| tags | 72 | 0.14% |

`sub-edition` and `sub-rarity` are an internal consistency check: identical draw counts and
structure, so a gap beyond ~0.02 is classification cost, not draw cost.

**CONFOUND:** `sub-vouchers` is not volume-neutral. Removing vouchers removes early-Overstock
frame growth, dropping card-type draws from 18,624 to 17,910 -- it deletes 3.8% of shop work too.
Subtract that before reading it.

**4. Isolating family (`iso-*`)** -- standalone cost, not a ceiling. **Sum the six, then subtract
five copies of the voucher spine** (~113 draws each, retained in all six because Overstock
sightings drive every other stream's volume). The gap between that sum and 1.000 is
**interaction cost** -- divergence, occupancy, cache pressure -- which no single-stream
optimization can reach. Predicted 20-40%.

**5. Divergence probes.** `div-resample-max / div-resample-mean` **is the divergence tax,
measured.** Draws rise only 1.22x between them (3,358x3 + 671x6 resamples vs the geometric mean
schedule), so anything materially above 1.22x is divergence rather than work. Where the shipped
filter sits between the two says how much headroom the depth-major rewrite left.

**6. Scheduling family (`sched-*`)** -- all bit-exact, zero draw-count change, so any movement is
pure scheduling. Two are inverted from their names because the shipped code already did the
literal thing asked for: `sched-interleaved-re` measures the **split** (a ratio of x implies 1/x
for what we ship), and `sched-packs-hoisted` hoists across the whole ante range because shops
already precede packs within an ante.

**CONFOUND:** `sched-interleaved-re` needs ~36 extra live registers at chunk 512, close to the
128-register cap. Check `--verbose_build` for spills before believing a slowdown there.

## Superseded fixtures

The 14 `diag_dns_abl_*` / `diag_dns_{maxframes,nolocks,uniform_frames,prefix*}` files copy the
PRE-REWRITE filter. They are marked SUPERSEDED and unwired from every profile; running them would
measure the old implementation and return ratios that look valid. `dns_sub_*` replaces them.
`diag_dns_baseline` is deliberately kept as the pre-rewrite regression control for the 2.076x.

---

## Pack-path A/B

```bash
python tests/run.py --profile diag-packs --scale rtx5080
```

`packs-phased / packs-legacy`. Both are bit-identical (verified 20,000 seeds), so any gap is
scheduling. The phased path draws all DNS_PACKS selections off one hoisted node state, then rarity
for every Buffoon card in the ante densely, then identities per pack (they must stay per-pack --
lock state is sequentially dependent within a pack), then editions densely.

Expect a gain on the GPU and roughly nothing on a CPU device: PoCL measured 1.010x, inside its own
0.990x control error, exactly as the shop staging measured 1.028x slower on PoCL before coming in
at 2.076x faster on the 5080.
