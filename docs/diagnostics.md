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
python3 tests/dispatch_bench.py calibrate --filter deep_negative_shops --cu 84 --target 10
```

It prints a calibrated `-n` and the probe time. **Send me that line.** If it suggests an `-n` far from
430,080, add `--count-scale` to every command below (e.g. `--count-scale 0.25` to quarter the runtime).

---

## Step 1 — the register/spill log (free, no benchmark)

Three of the four analyses independently named this the cheapest missing datum in the investigation.

```bash
./build/Immolate -f deep_negative_shops --verbose_build -n 1 -g 1 2>&1 | tee d0-verbose-build.txt
```

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
python3 tests/dispatch_bench.py g-sweep --filter deep_negative_shops --cu 84 --target 10
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
