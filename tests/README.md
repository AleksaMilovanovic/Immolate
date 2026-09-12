# Immolate test suite

The suite protects exact filter results and records repeatable benchmark timings. It uses only Python 3's standard library.

## Final correctness and benchmark gate

From the repository root:

```bash
python3 tests/run.py
```

The default `all` profile builds the Release executable, runs the compact regressions, executes the mandatory 32.2-million-seed breadth check, and runs the benchmark corpus. On a warm RTX 5080 it is intended to finish in a few minutes. A first run can take longer while the OpenCL driver compiles and caches each filter.

Results are written to an ignored directory such as:

```text
test-results/20260910T120000Z-bf6bf42/
```

The command prints the exact path when it finishes.

## Where kernels live

`filters/` holds **search filters**: kernels that take seeds in and produce a smaller set of seeds
out. `diagnostics/` holds **timing and cost-attribution fixtures**, most of which deliberately
return meaningless scores and exist only to be measured.

`-f <name>` takes a bare name and resolves it in either directory, so nothing about how you invoke
a filter changes. An unknown name reports both paths it tried.

## Diagnostic profiles

`tests/diagnostics.json` holds 43 ablation fixtures used to work out what the kernel is actually bound
by. They are timing-only and never compared against a golden.

```bash
python3 tests/run.py --profile diag-stage1 --scale rtx5080   # the three decisive experiments
python3 tests/run.py --profile diag-rng --scale rtx5080      # RNG component ablations + ILP probe
python3 tests/run.py --profile diag-dns --scale rtx5080      # DNS per-stream ablations
python3 tests/run.py --profile diag-mem --scale rtx5080      # footprint: ballast + CACHE_SIZE sweep
python3 tests/run.py --profile diag-all --scale rtx5080      # all of the above
```

**Every filter named `diag_*` produces deliberately wrong scores.** They are cost-attribution
ablations, not correctness artefacts; none may ever be added to `tests/golden/` or to a
golden-comparing profile. The exceptions are `diag_rng_a6_exact` and `dns_staged_resample*`, which
are exact and were verified score-identical to their baselines.

Benchmark seed counts are whole multiples of the RTX 5080 launch width (43,008 lanes = 84 CU x 16
groups x 32) so every lane gets at least ten seeds. Use `--count-scale` to trade wall time against
precision without editing the cases file, and `tests/dispatch_bench.py calibrate` to size a run for a
target duration first. Launch-geometry questions that no cases file can express (`-g` and local-size
sweeps, register caps, `--from` host I/O) live in `tests/dispatch_bench.py`.

See [docs/diagnostics.md](../docs/diagnostics.md) for the run order, what each fixture predicts under
each competing model, and how to read the results.

## Shorter profiles

```bash
# Small local compiler/correctness smoke test
python3 tests/run.py --profile smoke --scale pocl

# Compact correctness plus core benchmarks, without the large breadth gate
python3 tests/run.py --profile quick

# Compact correctness and equivalence checks only
python3 tests/run.py --profile correctness

# Mandatory 32.2-million-seed exact breadth gate only
python3 tests/run.py --profile breadth

# Timing corpus only
python3 tests/run.py --profile benchmark
```

Select a non-default OpenCL device with:

```bash
python3 tests/run.py --platform 0 --device 1
```

`--scale auto` selects the RTX profile only when the chosen device identifies itself as an RTX 5080. Other devices use conservative PoCL-sized benchmark cases unless `--scale rtx5080` is supplied explicitly.

PoCL is useful for correctness and OpenCL compiler coverage. Its timings are not representative of the RTX 5080.

## Correctness baselines

Small diagnostic snapshots and exact score hashes live under `tests/golden/compact/`. The breadth gate stores SHA-256 hashes for consecutive blocks of 65,536 exact signed 64-bit scores under `tests/golden/breadth/`. Its 32.2 million evaluations are split across `erratic_flush_five` and `brainstorm_blueprint`, covering the fp64 hash/RNG/deck path as well as shops, packs, rarity, locks, and joker identity selection.

Goldens never update automatically. After intentionally changing modeled behavior, inspect a comparison first, then refresh the selected profile explicitly:

```bash
python3 tests/run.py --profile correctness --update-golden
python3 tests/run.py --profile breadth --update-golden
```

Every changed golden path is reported. Timing data, device metadata, raw output, and complete breadth score streams are never committed.

## Comparing two runs

```bash
python3 tests/compare.py test-results/old test-results/new
```

The comparator retains the first 100 detailed differences by default while always reporting total counts. Pass `--max-examples 0` to retain every changed rank in the text and JSON reports.

It reports:

- missing or additional cases;
- missing/additional ranks and changed scores;
- the first changed diagnostic line with context;
- supplier metadata and rank-set changes separately;
- changed breadth hash blocks and their exact rank intervals;
- every changed rank and old/new score when both runs retained their `.scores` files;
- benchmark median and ratio changes without treating timing noise as a correctness error.

A text and JSON report are also saved under `test-results/comparisons/`.

Individual artifacts can be compared directly:

```bash
python3 tests/compare.py old.scores new.scores
python3 tests/compare.py old.immseeds new.immseeds
python3 tests/compare.py old-canonical.json new-canonical.json
```

Exit status is `0` for equal correctness, `1` for well-formed differences, and `2` for malformed input or a tool error.

## Exact checkout-to-checkout workflow

The tracked breadth golden identifies the exact 65,536-seed block in which a regression appears. To obtain every old and new score:

```bash
git checkout OLD
python3 tests/run.py --profile breadth --results test-results/old

git checkout NEW
python3 tests/run.py --profile breadth --results test-results/new

python3 tests/compare.py test-results/old test-results/new --max-examples 0
```

Each run retains its full score stream by default. Use `--discard-scores` only when disk usage matters and block-level diagnostics are sufficient.

## Artifact layout

```text
test-results/<run>/
  manifest.json              # source, executable, host and device provenance
  summary.json
  summary.txt
  cases/<case-id>/
    *.command.json
    *.stdout.txt
    *.stderr.txt
    canonical.json
    metrics.json
    *.scores                 # exact consecutive scores where applicable
    *.immseeds               # supplier pipeline artifacts where applicable
```

The new `--scores_to` application mode writes a portable score file:

- 96-byte little-endian header with magic `IMMSCORE`, format version, completion flag, filter, start rank and count;
- one little-endian signed 64-bit score for every consecutive input rank.

Incomplete, truncated, out-of-range, or trailing-data files are rejected by the independent Python reader.

## Benchmark methodology

Benchmark filters are warmed once before measurements so source compilation and first cache population are excluded. The suite uses `time.perf_counter_ns()` around the complete process and reports the median, minimum, maximum, p90, median absolute deviation, and coefficient of variation. Impossible cutoffs suppress result records.

These are end-to-end warm-process timings, not OpenCL event timings. They are suitable for the first optimization passes because benchmark ranges are large and commands are otherwise identical. Kernel-event instrumentation can be added after this correctness baseline is established.

Avoid other GPU workloads while collecting comparisons.

## Important correctness details

- Ordinary multi-seed output is produced concurrently and is not ordered. The suite parses seed/score records and sorts them by numeric rank before comparison.
- `wr_filter` two-pass and single-pass equivalence is checked only with a positive cutoff. Its prefilter does not represent score-zero seeds.
- `negative_tags` is run with cutoff zero when an exact final score is required; positive cutoffs may return valid lower bounds.
- Supplier files contain ranks, not scores. The suite compares their headers and rank bodies separately.
- A cache-overflow warning is always a failure. The cache remains memory-safe after overflow but subsequent modeled results are incorrect.
- Seed `114N` documents the deliberately unmodeled temporary same-window shop duplicate lock. Its stable Immolate output is tested; it is not expected to match that game behavior.
- FP contraction must remain disabled. Seeds `123I`, `11FC`, and `LP4K3AAQ` are included specifically because arithmetic changes have affected game-visible results before.

## Tool self-checks

The runner executes these automatically. They can also be run alone:

```bash
python3 tests/selfcheck.py
```

They cover seed/rank boundaries, score parsing, snapshot normalization, strict supplier and score-file validation, block hashing, and exact streamed score comparison.
