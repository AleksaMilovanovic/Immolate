# DNS optimization, 2026-09

`deep_negative_shops` got **3.738x faster** on an RTX 5080 — 8.577s to 2.295s over 344,064 seeds,
40,115 to 149,950 seeds/s. A billion-seed pool went from ~6.9h to ~1.9h.

Every change is **bit-exact**, verified by exact-score comparison over 20,000 seeds and by the
correctness goldens. **Not one of them removes a single RNG draw** — all five are scheduling.

## What landed

| change | gain | where |
|---|---|---|
| Depth-major identity resamples | 2.076x | `dns_flush_identities` |
| `-cl-nv-maxrregcount=128` on NVIDIA | 1.390x | `immolate.c` |
| Staging chunk 128 -> 512 | 1.164x | `DNS_CHUNK` |
| Staging chunk 512 -> 1024 | 1.031x | `DNS_CHUNK` |
| Pack path in four dense phases | 1.107x | `filter()` pack block |

**Depth-major resamples.** The lock-resample chain ran ordinal-major, so a warp paid
`sum over ordinals of max over lanes(1 + resamples)`. Resamples are geometric, so the max over 32
lanes is several times the mean. Depth-major costs `sum over depths of max over lanes(count)`, and
those counts are binomial and concentrate.

**Register cap.** Left alone the compiler used 137-154 registers, allowing only 12-14 of 48 possible
warps per SM. Capping at 128 gives 16. There is a hard cliff between 136 and 128 and a flat floor
below it — 120/112/96 land within 0.5% of 128 — so cap at 128 and no lower.

**Chunk size.** 1024 is the saturation point: the largest ante has ~660 joker cards, so any chunk
>= 1024 is one chunk per ante. 2048 measures identically, confirming that. A predicted
register-pressure regression at 1024 did not happen — the masks are dynamically indexed, so they
live in local memory and cost frame bytes, not registers.

**Pack path.** Only ~8.7% of packs are Buffoon, but with 32 lanes there is a 94.5% chance some lane
enters the body, so every lane paid for it and the selection draws were serialised behind that.
Now: all selections off one hoisted node state, then rarity for every Buffoon card densely, then
identities per pack, then editions densely. Exact because each of those streams lives on its own
ante-keyed node and still sees its own draws in the same order — only the interleaving across nodes
changed. Identities must stay per-pack: a card is temporarily locked while later cards in the same
pack are drawn.

## Measured cost profile

Draw counts do not predict cost. Cost per draw spans 170x:

| stream | draws/seed | draw % | time % | cost/draw |
|---|---:|---:|---:|---:|
| pack contents | 170 | 0.32% | 23.0% | 71x |
| vouchers | 115 | 0.22% | ~10% | 64x |
| pack selection | 216 | 0.41% | 16.8% | 41x |
| rare identity resamples | 807 | 1.54% | 13.1% | 8.5x |
| uncommon identity resamples | 1,739 | 3.32% | 10.7% | 3.2x |
| card type | 18,624 | 35.6% | 13.6% | 0.4x |
| rarity / edition | 13,293 each | 25.4% each | 11.4% / 10.2% | 0.4x |

Measured before the pack change. The staged shop streams are the cheapest per draw in the filter;
packs and vouchers were the last on the un-staged path.

## Tried and rejected, with the number that killed it

| idea | verdict |
|---|---|
| Exact prefilter / mid-run abandon | **Impossible.** The score is monotone in antes, so a prefix is a lower bound: 54.1% false negatives at antes 3-24. |
| Any fp64 / RNG-core optimization | **Capped at 7.3%.** Removing the *entire* RNG core buys 7.3% (register-pinned). |
| `rng_advance_int` integer node recurrence | 7.2% ceiling, needs a lane-divergent fallback. Not worth it. |
| GF(2) jump-ahead for the Tausworthe warmup | The warmup is **0.6%**. Also predicted a net loss: the table lookups cost more than the ops they remove, and NVIDIA `__constant` reads with lane-divergent addresses serialise. |
| Software binary64 `randomseed` | **+7.8% cost** at realistic INT32 rates. |
| ILP / interleaving independent RNG streams | Chain probe flat at K=1..8 — not latency-bound. Also tried at K=2 historically: 1.045x slower. |
| Hash-indexed RNG node cache | **0.14% of a seed.** The MRU hint, reverse scan and ante-local cache already cut key compares 1,693x. |
| Seed bucketing by Overstock profile | Uniform frame sizes measure 0.970x for 4.7% fewer draws — the divergence is already gone. |
| Seed-level work redistribution | 9.4% oracle ceiling before the scheme pays its own costs. |
| Launch geometry (`-g`) | Best alternative 1.056x, and superseded by the register cap. |
| `--from` host I/O, `COLLECT_CHUNK`, `i_init` array clears | 0.2%, <1e-6, 0.008%. |
| Private-memory footprint (`CACHE_SIZE`, struct trimming) | The *touched* node set is ~900 B/thread and invariant in `CACHE_SIZE`; `instance` lives in local memory, so it is not an occupancy step function. |
| Scheduling variants: rare-before-uncommon, split rarity/edition, packs hoisted across antes | 0.990x, 1.003x, 1.011x. Nothing there. |

## Still open

- **Vouchers, ~10%.** One voucher per ante on an ante-keyed node with a strictly sequential resample
  chain: no batch to densify, nothing to hoist, and the order cannot change. No easy exact win.
- **Buffoon identities, ~66 draws/seed.** Sequentially dependent on lock state within a pack.
- Packs are still ~31% of the (now smaller) total, concentrated in those two.

## If you measure this again, read this first

Unpinned, this kernel's register allocation moves between 12/14/15/16 resident warps on almost any
source edit — worth up to **12%**, larger than most effects worth measuring. It invalidated an entire
ablation run: 1 KB and 4 KB of dead ballast measured identically, as did 2 KB and 8 KB. The NVIDIA
build now pins registers by default.

`tests/diagnostics.json` therefore ships a **control pair**: `ctl-a` and `ctl-b` are byte-identical
and must read **1.000x +/- 0.5%**. If they do not, nothing else in that run is readable.

```bash
python tests/run.py --profile diag-packs --scale rtx5080   # pack restructure A/B
python tests/run.py --profile diag-chunk --scale rtx5080   # DNS_CHUNK sweep
```

Every fixture in `diagnostics/` is a thin `#include` wrapper around the live filter, so none can
drift out of sync with it. The earlier factor-isolation suite was built from *copies* and was
deleted: because the pack change is bit-exact, a stale copy produced identical scores while timing
the old code — undetectable by any score check.
