# Where the kernel's time goes (RTX 5080, 2026-09-16)

A filter-independent breakdown of the search kernel: which hardware resource
binds, what each library primitive costs, and how the time of a seed splits
between the fixed per-seed work, the RNG library and lane divergence. Nothing
here is per-filter tuning; five filters of different shape (`erratic_flush_five`,
`brainstorm_blueprint`, `wr_filter`, `negative_tags`, `deep_negative_shops`) are
used only as workload samples for the same model. All numbers are medians of 3
runs of 1.3 to 1.7 s each; run-to-run spread was 0.3% median, 1.4% at p90.

## Summary

Two things bind, in this order:

1. **Intra-warp divergence.** When lanes of a warp take different paths (lock
   resample loops, item-type branches, early exits), the fp64 pipe still spends
   its full 16 clocks per warp instruction on the active lanes only. Giving every
   lane of a warp the same seed, with everything else unchanged, made the sample
   filters run 1.2x (deck), 1.9x (`wr_filter`), 4.8x (`negative_tags`) and 6.4x
   (`brainstorm_blueprint`) faster. Straight-line code (a bare draw loop, the
   per-seed floor) gains nothing from it, so the loss is entirely in branchy
   library paths and filter code, not in the RNG arithmetic.
2. **fp64 pipe throughput.** With divergence removed, every filter's time is
   reproduced to within 2% by `counts x unit costs` where the unit costs are all
   fp64-pipe time: a hashed character (`ph_step`) is 30 fp64-op equivalents, a
   draw (`rng_node_advance` + `randomseed`) is 23, a new RNG node (name hash) is
   ~350, about 12 characters. Creating a node costs as much as 15 draws, and node
   creation is the largest arithmetic item in every sample filter except the
   deck one (52% to 98% of the non-divergent time).

Everything else is small: the node cache and its linear scan are ~2% of a draw,
local memory is free at this occupancy, the integer Tausworthe core hides under
the fp64 work (0.8 ps of a 33 ps `randomseed`), constant-table reads with
divergent lanes cost 3% of a draw, registers and occupancy are not limiting
(dependent fp64 chains run at pipe throughput), the GPU holds 2850 MHz at 190 to
215 W of a 360 W cap with no throttle flags, and host + launch overhead is ~0.11 s
per process. One item that is not small and is paid by every seed: deriving the
seed from its rank costs 0.83 ns, three times the seed's own hash, because the
digit loop spills the 64-byte seed vector to memory on every digit.

## Method

Everything is in the tree and reproducible with nothing beyond the OpenCL
driver (no CUDA toolkit is installed on this machine, so no Nsight; the
`.kernel_cache/*.bin` files are PTX for sm_120 and were analysed statically).

- `diagnostics/prim_common.cl` + `diagnostics/prim_<kind>.cl`: 26 primitive
  microbenchmarks. Each runs `PRIM_K` data-dependent repetitions of one
  primitive per seed; the cost of one repetition is the slope between two
  `PRIM_K` builds (`--build_opts -DPRIM_K=...`), so the per-seed floor cancels.
- `lib/instance.cl`, `lib/functions.cl`: operation counters behind
  `DIAG_COUNTERS` (compiled out by default; the PTX of the committed and the
  instrumented library was compared and is byte-identical).
  `diagnostics/diag_count_<f>.cl` returns two counters packed in the score,
  read back with `--scores_to`.
- `diagnostics/diag_uni_<f>.cl`: the real filter on a seed whose rank is masked
  with `~UNI_MASK`: 0 = control (pays the same extra `s_tell`/`s_from_rank`/
  `i_init`), 31 = every lane of a warp gets the same seed, 0x7FFFFFFF = the
  whole launch gets one seed. Start rank `1111111H` is a multiple of 32.
- `tests/profile_kernel.py` with the plans in `tests/kernel_profile/` runs all
  of it sequentially (warm-up, adapt `-n` to ~1.6 s, 3 timed runs, keep both the
  process's "Done in" and the external wall time); `tests/profile_analyze.py`
  prints the tables below; `tests/ptx_mix.py <bin> search` gives the static mix.
- Register, stack and spill figures: `--verbose_build`.

## Machine ceilings as measured

| quantity | measured | note |
|---|---:|---|
| fp64 FMA, 8 independent chains | 2.72 ps/op = 368 G/s | 1.54 per SM-clock at 2850 MHz; nominal is 2 |
| fp64 FMA, one dependent chain | 2.69 ps/op | identical: fp64 latency is fully hidden at 16 warps/SM |
| int32 IMAD, 8 chains | ~0 (below noise) | 1/64 of the fp64 cost, as expected |
| SM clock under load | 2850 MHz | 190 to 215 W of 360 W, 59 C max, throttle mask 0 |
| kernel launch + drain, 1 seed/lane | 18 ms | fixed per process; same at 4 and 16 seeds/lane |
| process wall minus in-process time | 107 ms median | OpenCL setup + cached binary load; 178 ms for the largest kernel |

The fp64 pipe is the reference unit below: **1 fp64-op equivalent = 2.72 ps**.

## Primitive unit costs

Slope per repetition, dependent chain, 16 warps/SM. Static column: fp64-pipe
class PTX instructions in the primitive's loop body (fma, mul, add/sub, floor/
trunc/round, 64-bit converts), which matches the measured equivalents.

| primitive | ps | fp64-op eq | static fp64 PTX |
|---|---:|---:|---:|
| `fract(h*a+b)` (mul, add, floor, sub) | 10.3 | 3.8 | 4 |
| fp64 -> s64 -> fp64 round trip + 3 ops | 12.6 | 4.6 | 5 |
| `div_pos` (+ fract, mul, add) | 36.8 | 13.5 | ~14 (5 fma, 3 mul, 2 add, 1 floor, 3 f32 converts + rcp) |
| **`ph_step`, one hashed character** | **81.5** | **30.0** | 28 + 3 f32 converts |
| `rng_node_advance` on a register | 31.9 | 11.7 | 13 |
| `randomseed` fp64 seeding + 1 draw, no warmup | 32.2 | 11.8 | 12 |
| `randomseed` full (+10 Tausworthe warmup) + 1 draw | 33.0 | 12.1 | 12 fp64 + 285 int64 PTX ops |
| 11 Tausworthe steps alone | 14.5 | 5.3 | 268 int64 PTX ops |
| **full draw, register state** (advance + randomseed + randint + table read) | **62.1** | **22.8** | 22 |
| full draw, production path on a cached node | 63.2 | 23.2 | + key build, `lastNode` compare, local-memory state |
| `get_node_child`, `lastNode` hit, no reseed | 32.1 | 11.8 | |
| lookup walking ~31 keys, then advance | 33.8 | 12.4 | scan of 31 keys = 1.6 ps |
| **node creation** (3-part name, seed part cached) | **963** | **354** | ~12 `ph_step` |
| node creation with the cache emptied first | 958 | 352 | the scan is free |
| `__constant` table read, divergent lanes | 2.0 | 0.7 | |
| `__constant` table read, uniform lanes | 0.1 | 0.0 | |
| dependent local-memory load+store pair | 0.16 | 0.06 | |
| `i_init` (8 `ph_step` for the seed + field init) | 667 | 245 | |
| `s_tell` | 288 | 106 | dynamic index into `ulong8` |
| **`s_from_rank`** (dependent chain) | **826 to 842** | **~305** | see below |
| `s_from_rank` (independent ranks) | 886 | 326 | throughput-bound, not latency |

`s_from_rank` is the anomaly: eight divides by 35 compile to `mul.hi.s64`
sequences (no software divide), but `s.data[s.len] = digit` is a dynamic index
into a `ulong8`, and the PTX loop stores the whole 64-byte vector (4 `st.v2.u64`),
does the indexed `st.u64`, then reloads all four `ld.v2.u64` on every digit, and
again in the reversal loop. That traffic, not arithmetic, makes it cost more than
the seed's whole 8-character hash. The same construct makes `s_tell` 106
fp64-op equivalents.

Note the randomseed warmup: 11 Tausworthe steps cost 14.5 ps on their own but
only 0.8 ps inside `randomseed`, because the int32 pipe runs them under the fp64
seeding. Per draw the integer work is ~580 SASS int32 instructions against 23
fp64 ops x 16 clocks; the integer issue time is ~60% of the fp64 pipe time, so
it stays hidden only while the fp64 work stays this large.

## Per-seed floor

`prim_empty` (search loop, `s_from_rank`, `i_init`, trivial filter):
**1.017 ns/seed**, 983 M seeds/s. Its parts measured alone sum to more
(`s_from_rank` 0.83 + `i_init` 0.67 = 1.50) because they bind different
resources (memory traffic vs fp64 pipe) and overlap across warps. In a filter
that is itself fp64-bound less of that overlap is available: adding one extra
`s_tell` + `s_from_rank` + `i_init` to the deck filter cost 1.51 ns.

## Dynamic operation counts per seed

Means over 65,536 seeds (16,384 for `deep_negative_shops`), full-score path.

| filter | node resolves | node creates | lastNode hits | scan compares | advances | reseeds | draws | name chars hashed | seed chars hashed | init chars |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| erratic_flush_five | 52 | 1 | 51 | 0 | 52 | 52 | 52 | 7 | 8 | 8 |
| brainstorm_blueprint | 37.5 | 8.9 | 11.0 | 70 | 37.5 | 37.5 | 37.5 | 85 | 19 | 8 |
| wr_filter | 2.4 | 1.3 | 1.0 | 0.5 | 2.4 | 2.4 | 2.4 | 14 | 11 | 8 |
| negative_tags (cutoff 0) | 88.6 | 49.6 | 32.9 | 28 | 88.6 | 88.6 | 88.6 | 352 | 32 | 8 |
| deep_negative_shops | 840 | 776 | 50 | 8,403 | 261 | 261 | 261 | 11,854 | 110 | 8 |

## Cost model against measurement

Predicted = floor (1.017, includes the probe's extra `i_init` as 8 x 81.5 ps) +
hashed characters x 81.5 ps + draws x 63.2 ps. Compared with the **warp-uniform**
probe (no intra-warp divergence) and the **control** probe (production
divergence, same extra work).

| filter | predicted ns | warp-uniform ns | control ns | divergence share | hashing share of non-div. | draws share |
|---|---:|---:|---:|---:|---:|---:|
| erratic_flush_five | 6.18 | 6.16 | 7.40 | 17% | 20% | 53% |
| brainstorm_blueprint | 12.47 | 12.74 | 81.22 | 84% | 66% | 19% |
| wr_filter (`--single_pass`) | 3.83 | 3.79 | 7.19 | 47% | 52% | 4% |
| negative_tags (cutoff 0) | 38.5 | 38.7 | 185.4 | 79% | 81% | 15% |
| deep_negative_shops | 994 | n/a | 8,213 (8 seeds/lane) | see note | 98% | 2% |

The arithmetic model is exact to 2% on four shapes of filter, so there is no
hidden cost left in the straight-line path: no memory, cache, occupancy or
integer term is needed. Whole-launch-uniform seeds land within 3% of warp-uniform
in every case, so cross-warp imbalance is negligible for launches of 1,000+
seeds per lane.

`deep_negative_shops` note: at 344,064 seeds (8 per lane) the launch is bounded
by its slowest warp. Warp-uniform seeds make it 5x *slower* (14.4 to 15.0 s vs
2.8 s), because each warp then carries 8 whole heavy-tailed seeds instead of the
average of 256, so the intra-warp share cannot be isolated at that size; the
depth-major work in `docs/optimization.md` already addresses it. Its arithmetic
floor of ~1 us/seed against ~8 us measured says the same thing as the other
filters, more strongly. Two of the six fixed-count runs of it also took 18 s
instead of 2.8 s (identical work, both plain and control); the cause was not
identified and it was never seen on launches shorter than 2.8 s.

## Static instruction mix of the `search` entry (PTX, sm_120)

| kernel | static instrs | frame B | fp64 class | int64 | int32 | local/generic mem | branches | `div.rn.f64` (fallback, never taken) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| erratic_flush_five | 2,499 | 3,968 | 30% | 23% | 17% | 21% | 4% | 19 |
| brainstorm_blueprint | 20,607 | 7,040 | 42% | 18% | 14% | 4% | 13% | 254 |
| wr_filter | 11,625 | 12,800 | 42% | 19% | 12% | 5% | 12% | 142 |
| negative_tags | 10,706 | 4,480 | 41% | 18% | 13% | 5% | 13% | 130 |
| deep_negative_shops | 875 (+ out-of-line `filter`) | 6,400 | | | | | | |

The fp64 class includes add/sub. Every `ph_step` carries an inlined
`div.rn.f64` for the `b < 1e-37` fallback; it costs a compare and a branch per
character and code size, never the divide.

## Registers and occupancy

| kernel | registers | stack frame | spills |
|---|---:|---:|---|
| erratic_flush_five | 96 | 4,016 B | none |
| brainstorm_blueprint | 102 | 7,088 B | none |
| wr_filter | 128 (cap) | 29,424 B | none |
| negative_tags | 106 | 4,528 B | none |
| deep_negative_shops | 128 (cap) | 20,976 B | 16 B stores / 8 B loads |

The launch is 16 work-groups per SM x 32 lanes = 16 warps/SM regardless of
registers, so occupancy is set by geometry, not allocation. At that occupancy a
single dependent fp64 chain already runs at pipe throughput, so more warps
cannot buy anything on the arithmetic side. Stack frames of 4 to 29 KB x 43,008
lanes are 170 MB to 1.3 GB of local memory, yet dependent local load/store
pairs measured 0.16 ps and 31-key scans 1.6 ps: the hot part of `instance` is
cache-resident and local memory is not a factor.

## Ruled out or negligible

- **fp64 latency / ILP.** Dependent chain = independent chains. Interleaving
  streams cannot help (matches the K=1..8 chain probe in `optimization.md`).
- **Integer RNG core.** Hidden under fp64 (0.8 ps of 33). Becomes visible only
  if the fp64 work per draw drops by ~40%.
- **Node cache.** Hit path costs 1.1 ps over register state (1.8% of a draw);
  a 31-entry scan 1.6 ps; the cache-emptied node creation equals the growing one.
- **Local memory footprint.** Free at this occupancy for the hot set.
- **Constant memory.** 2 ps per divergent table read, one per draw.
- **Cross-warp imbalance.** Under 3% for long launches; dominant only for
  short launches of heavy-tailed filters (8 seeds/lane above).
- **Clocks, power, thermals.** 2850 MHz steady, no throttling.
- **Host and launch.** ~0.11 s per process, independent of `-n`.

## What this means for optimisation (ranking only)

1. Divergence is the first-order loss for every filter with resample loops or
   item-type branches: 47% to 84% of wall time on three of four sample shapes.
   The fp64 pipe is charged 16 clocks per warp instruction whether 1 or 32 lanes
   are active, so anything that keeps lanes on the same path (or fills idle
   lanes) pays back directly.
2. Node-name hashing is the first-order arithmetic cost: ~12 `ph_step` x 30
   fp64 ops per new node, 52% to 98% of the non-divergent time outside the deck
   filter. Fewer node creations, fewer characters per name, or a cheaper
   `ph_step` (28 fp64-pipe ops for one character today) are the levers.
3. The draw itself is 23 fp64 ops, split evenly between `rng_node_advance`
   (`roundDigits` is 8 of its 12) and `randomseed`'s four multiply-adds.
4. The per-seed floor is 1.0 ns, 17% of the deck filter and 16% of `wr_filter`:
   `s_from_rank`'s vector spill (0.83 ns) is larger than the seed hash (0.65 ns).

## Optimisations made from these numbers (2026-09-16, same machine)

Each step was checked with the correctness gate and by re-running the affected
primitives and the five sample filters (`tests/kernel_profile/verify.json`,
pinned to single launches). Ratios are raw medians of 3 runs against the
previous step; a primitive the step cannot touch (the draw slope, 63 to 61 ps
throughout) served as the drift reference and stayed within 2%.

| step | what | negative_tags | brainstorm | wr_filter | deck | deep shops (430k) | primitive |
|---|---|---:|---:|---:|---:|---:|---|
| 1 | name-suffix hash-state cache | 0.83 | 0.91 | 0.94 | 1.00 | 0.91 | hashed chars: negtags 352 -> 282, deep shops 11,854 -> 8,378 |
| 2 | `ph_step`: trunc + fp64 reciprocal seed | 0.93 | 0.93 | 0.92 | 0.98 | 0.97 | node creation 946 -> 882 ps |
| 3 | `s_from_rank` / `s_tell` without the vector spill | 0.98 | 0.98 | 1.00 | 0.88 | 0.99 | per-seed floor 1.02 -> 0.585 ns |
| 5 | depth-major batches and dense shop/pack phases (`randchoice_common_batch`, `shop_items_dense`) in the three branchy filters | 0.45 | 0.61 | 1.00 | 1.00 | 1.00 | non-divergent (warp-uniform) time unchanged |
| **1-3, 5 combined vs baseline** | | **0.35** | **0.52** | **0.90** | **0.88** | **0.89** | |
| 4 | host: single-pass range in ~1 s launches (`--launch_seconds`) | | | | | see below | printed records kept at cutoff 7: 35% -> 91-99.9% |

All kernel changes are bit-exact: the suite's goldens pass unchanged, the
`ph_step` rewrites were probed for bit-identical results over 5.1e9 inputs
per variant including 0, inf and NaN (`diagnostics/probe_phstep_variants.cl`),
and the seed rewrite gives identical records on 1- to 8-character seeds.

**Step 1.** The parts of a node name are hashed last-first after the seed, so
the state after `seed + "3_resample7"` is the same for `Joker2buf3_resample7`
and `rarity3buf3_resample7`, and the state after `seed + "1"` is shared by
every node of ante 1. `rng_node_resolve` now memoises those suffix states in a
64-entry direct-mapped cache in `instance` (`SUFFIX_CACHE_BITS`), longest
suffix first, exactly like the existing per-length seed cache. Two register
lessons cost a round each: the first version kept small key/length arrays and
spilled ~1 KB per lane in the two kernels at the 128-register cap (deep shops
6x slower), and passing the callers' compound-literal arrays to the now
out-of-line hasher made every call site materialise them (deck filter +2.5%).
The hasher decodes the parts from the packed key instead.

**Step 2.** Three exact rewrites of `ph_step` were probed; two were kept. The
per-position table for `pi*pos` measured no gain on node creation and slowed a
dependent chain, so the multiply stays.

**Step 3.** Digits are peeled into scalars with compile-time vector indices;
the dynamic index into `ulong8` was what forced the 64-byte spill per digit.

**Step 5.** Two library helpers turn "some lane in the warp needs this" into
"max over lanes of a binomial count". `randchoice_common_batch` runs many
`randchoice_common` requests with the resample chains depth-major, each lane
walking its own list of still-locked requests; `shop_items_dense` draws a shop
window in phases (types, rarities, identities per pool through the batch
helper, stickers, editions, other items). Pack loops draw every pack type
first and then walk the lane's own list of Buffoon packs. All exact by the
node-order argument the deep-shops filter already relies on: only the order
of draws within one node can matter, and every node is still consumed in
request order. Score streams of the three converted filters are bit-identical
to the committed library over two 65,536-seed ranges, and the suite passes.
negative_tags batches antes 2-38 in chunks of 19 (ante 1 has its own lock
set); its `-c` early exits are checked between chunks, which decides the same
pass/fail set with exact rather than lower-bound scores for the survivors.

## Distance from the floor after the five steps

Same definitions as before: *floor* is the mandatory work (hashed characters
after the suffix cache, draws, the 8-character seed hash) at the measured unit
costs with no divergence and no per-seed overhead; *ideal* is the irreducible
operation count (18 fp64 ops per hashed character, 20 per draw) at the nominal
2 ops per SM-clock. "Warp-uniform" is the measured speed with every lane of a
warp on the same seed, i.e. the same code with divergence removed.

| filter | before, M seeds/s | now | warp-uniform | floor | ideal | of floor | of ideal |
|---|---:|---:|---:|---:|---:|---:|---:|
| erratic_flush_five | 170 | 193 | 176 | 207 | 329 | 93% | 59% |
| brainstorm_blueprint | 12.5 | 24.3 | 88 | 100 | 180 | 24% | 14% |
| wr_filter (single pass) | 153 | 171 | 301 | 400 | 755 | 43% | 23% |
| negative_tags (cutoff 0) | 5.4 | 15.8 | 33 | 35 | 63 | 45% | 25% |
| deep_negative_shops | 0.12 | 0.14 | | 1.6 | 3.0 | 9% | 5% |

What is left, and where it was measured to be:

- **negative_tags: all of it is resample handling.** With the profile's tag
  locks compiled out (`-DNT_NO_LOCKS`, no rerolls at all) the divergent and
  warp-uniform runs are identical, 21.05 vs 21.01 ns, so the base phase has
  zero divergence. The resample phase costs 43.6 ns at warp level against 9.4
  ns per lane. The inherent part is the max over 32 lanes of a binomial
  pending count (about 1.6x on that phase). The rest has two causes: ante 1
  is drawn on its own with half the tag pool locked, a geometric chain whose
  max over 32 lanes is 5 to 6 rerolls per slot; and each lane's first use of a
  `_resample<k>` suffix for a given name length misses the suffix cache at a
  different position of its pending list, so the warp pays a full 14-character
  hash on most positions instead of the 4 to 5 characters a hit leaves.
  Pre-warming the two `_resample<k>` suffix states per depth uniformly across
  the warp before the pending loop would remove the second cause (estimated 5
  to 8% of the filter); it is the next thing to do in `randchoice_common_batch`.
- **brainstorm_blueprint: packs.** Shops alone run at 21 ns per seed, packs
  alone at 31; inside a Buffoon pack the Rare identities are drawn one card at
  a time because each card locks itself for the rest of the pack, so a card's
  resample chain (11 of 20 Rares locked, max over lanes 6 to 7 rerolls) cannot
  be batched with the next card's. Only cross-pack batching of the *first*
  card of each pack is exact; the rest is inherent to the pack rules.
- **wr_filter: the gate.** 99.9% of seeds leave at gate 1 while 0.07% run 36
  antes; that is the remaining 2.3x and it belongs to staged compaction (a
  second prefilter stage), not to the kernel.
- **deep_negative_shops** keeps its own dense code; its 9% is the same
  structure at 38 antes plus the slow-mode issue above.

Two supporting measurements: a node creation or a draw costs the warp exactly
the same whether 1, 8 or 32 lanes perform it (1.00x measured with
`prim_divcreate` / `prim_divdraw`), which is the premise of every estimate
here; and a 256-entry suffix cache (`-DSUFFIX_CACHE_BITS=8`) cut deep shops'
hashed characters 13% and its time 3% but moved the other filters by +-1.5%
(noise), so the default stays at 64.

**Not done, and why.** Divergence itself (47-84% of the branchy filters) is
structural: the resample loop's trip count is per lane. Its cost per divergent
iteration has been cut by steps 1-2 (a resample node is now hashed from the
shared `_resample<k>` state), but the remaining lever is scheduling inside the
filters, which `docs/optimization.md` covers for deep shops. The draw (23 fp64
ops) has no exact shortcut left: `roundDigits` needs its correction FMAs and
`randomseed`'s four multiply-adds are the game's own two-rounding sequence.

**Step 4 and two things found on the way.** The plain single-pass search ran
its whole range as one kernel launch. It now walks the range in launches of
about `--launch_seconds` (default 1; 0 restores one launch), scaling the launch
size from measured time. Cost on the cheap deck filter over 2e9 seeds: 9.52 s
-> 9.55 s. Two effects motivated it:

- *Silent record loss in the print path.* Records are printed by the kernel's
  `printf`, whose buffer holds roughly 110k records per launch. Over 100M
  deck-filter seeds at cutoff 7 (316,056 true records, exact via `--to`), one
  launch printed 110,811 (35%); 0.25 s launches printed 287,434 and 0.2 s
  launches 315,836 (99.9%). At cutoff 8 (34,517 records) every mode printed
  all of them. Any run expected to print more than ~100k records should use
  `--to` (exact) or short launches.
- *Intermittent 4x to 18x slowdowns of `deep_negative_shops`* (no other sample
  filter ever showed it, and the committed library shows it too). Identical
  work: 2.6 to 2.9 s good, 21 to 37 s bad at 344k seeds; 8 s good, 127 to 155
  s bad at 1.29M seeds. While bad: SM at 2850 MHz, memory clock full, 100%
  utilisation, all memory in dedicated VRAM, power 70 W instead of 190 to 215
  W, so the SMs are stalled, not throttled. It comes and goes over a session
  (1 in 3 early, 4 of 4 for a stretch, then 0 of 4 again minutes later), and
  it is confined to the two kernels that contain `printf` (`search`,
  `search_ranks`) at the default 16 work-groups per SM: back to back on the
  same seeds, the collect kernel (`--to`) took 7.8 s, the score kernel
  (`--scores_to`) 7.8 s, the print kernel 127 to 155 s three times running,
  and the print kernel at `-g 1176` (14 per SM) 8.0 s. Ruled out by direct
  test: launch length (0.25 s launches were slow 4 of 4), a register cap of 96,
  private-memory paging, and footprint alone (the deck filter with a 20 KB
  frame stayed fast). At 12 per SM it still struck 1 of 2. The root cause was
  not identified. `-g 1176` was fast in every one of 8 runs and is 9% faster
  than a good full-width run for this filter; it costs 0.4 to 2% on the cheap
  filters, so the default stays at 16 and `-g 1176` is the documented
  mitigation for heavy printing runs (`--to` is unaffected and also exact).

## Second scope: juggle_tag, early_ante_perkeo, immolate_sixth_sense, negative_tags, early_negative_rares

Same method (single-pass timings, warp-uniform probes, counters; score streams
bit-identical to the committed library on two 65,536-seed ranges each; suite
passes). "Before" is the state after the first five steps above; against the
original baseline negative_tags is 3.7x faster (185 -> 49 ns).

| filter | before ns | now ns | speedup | warp-uniform | floor | ideal | of floor | of ideal | now, M seeds/s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| juggle_tag | 1.61 | 1.54 | 1.04x | 2.10 | 1.58 | 0.83 | 100% | 54% | 650 |
| early_ante_perkeo | 31.6 | 12.9 | 2.45x | 9.2 | 8.3 | 4.5 | 64% | 35% | 78 |
| immolate_sixth_sense | 142.4 | 69.0 | 2.06x | 20.1 | 19.6 | 10.7 | 28% | 15% | 14.5 |
| negative_tags (cutoff 0) | 61.1 | 49.4 | 1.24x | 28.4 | 28.8 | 15.9 | 58% | 32% | 20.2 |
| early_negative_rares | 412.6 | 393.7 | 1.05x | 216.2 | 170.2 | 111.1 | 43% | 28% | 2.5 |

What was done, and what each filter's remaining gap is:

- **juggle_tag** was already at its floor (one draw, no rerolls: warp-uniform
  equals divergent). Its 1.5 ns is the seed hash, the seed re-hash at the
  node's name length and the 5-character name. Nothing to do; note that at a
  1-in-24 hit rate its printed output overflows the printf buffer immediately,
  so it must be run with `--to`.
- **early_ante_perkeo**: pack types first, then each lane walks its own list of
  Arcana/Spectral packs, with both soul-poll nodes resolved for the whole warp
  up front (each lane used to create them at its own first candidate slot, so
  the warp paid the creation at every slot). 2.45x. The rest is the per-card
  poll loop inside `pack_has_soul` (pack sizes 2 to 5 differ per lane) and the
  Perkeo draw.
- **immolate_sixth_sense**: the creation check turned out to be the largest
  divergent item, not the shops: `SPECTRALS` holds two locked placeholder
  entries (the Soul and Black Hole slots), so one draw in nine rerolls and the
  check alone measured 4.5x its warp-uniform time. Both sources' draws over the
  three antes are now one depth-major batch each; the shop scan uses the dense
  window (Uncommon identities only) and the pack list-walk. 2.06x. A prefilter
  on the creation check exists behind `SS_PREFILTER` but measured a wash (the
  survivors still diverge among themselves), so it is off. The remaining 3.4x
  is the 42% of lanes that exit after the check, the per-lane number of antes
  scanned, and the in-pack Uncommon chains, which lock card by card.
- **negative_tags**: the batch helper now pre-warms the shared `_resample<k>`
  suffix states at depths 1 and 2 so no lane's first miss costs the warp a
  full hash mid-list (11%), and ante 1 is its own two-request batch (10%).
  With `-c 400` for pool building it is 3.2x faster than the committed
  version (1.06 s vs 3.36 s over 20M seeds). The rest is the binomial max
  over lanes of pending rerolls, inherent to depth-major.
- **early_negative_rares** was left alone: it is already dense scalar streams,
  and its 1.8x divergence is per-seed frame size (an Overstock lane has 1.5x
  the cards of the others, and the warp runs to the longest) plus the voucher
  reroll chain whose lock set changes every ante, so it cannot be batched
  across antes. Its counters also undercount draws (it calls `randomseed`
  directly), which is why its warp-uniform time exceeds the tabulated floor.
