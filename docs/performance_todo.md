# Performance follow-ups

> **2026-09-11 RESULTS — RTX 5080, 344,064 seeds of deep_negative_shops.**
> **3.375x landed and bit-exact** (8.577s -> 2.541s; 40,115 -> 112,808 seeds/s).
>
> | change | speedup |
> |---|---|
> | depth-major identity resamples + staging chunk | 2.076x |
> | `-cl-nv-maxrregcount=128` on NVIDIA (12-14 -> 16 resident warps) | 1.390x |
> | staging chunk 128 -> 512 | 1.164x |
> | staging chunk 512 -> 1024 (saturation: one chunk per ante) | 1.031x |
> | **cumulative** | **3.375x** |
>
> Pending measurement: the pack path restructured into four dense phases
> (`diag-packs` profile; `dns_packs_legacy` is the A/B baseline).
>
> ## Measured cost profile (factor-isolation suite, `--profile diag-factors`)
>
> Draw counts do NOT predict cost. Cost per draw spans 170x across streams:
>
> | stream | draws | draw % | time % | cost/draw |
> |---|---:|---:|---:|---:|
> | packcontents | 170 | 0.32% | 23.0% | 71x |
> | vouchers | 115 | 0.22% | 14.1%* | 64x |
> | packsel | 216 | 0.41% | 16.8% | 41x |
> | rareid-resample | 807 | 1.54% | 13.1% | 8.5x |
> | uncid-resample | 1,739 | 3.32% | 10.7% | 3.2x |
> | cardtype | 18,624 | 35.6% | 13.6% | 0.4x |
> | rarity / edition | 13,293 each | 25.4% each | 11.4% / 10.2% | 0.4x |
>
> \* includes a 3.8% frame-growth confound (removing vouchers removes early
> Overstock, shrinking every shop); vouchers alone are ~10%.
>
> The staged shop streams are now the CHEAPEST per draw in the filter. Packs and
> vouchers were the last streams on the un-staged lib path.
>
> ## Closed by measurement
>
> - **No interaction cost.** Isolated stream costs sum to ~100% of the whole
>   filter (1.605 raw, ~1.05 after subtracting five duplicated voucher spines).
>   Single-stream optimization works; there is no hidden occupancy penalty.
> - **Divergence is essentially solved.** forced-max/forced-mean resample depth =
>   1.097x time for 1.22x draws, so uniform work is now *cheaper* per draw. Only
>   ~8.8% of resample divergence remains. Uniform joker counts 1.004x and uniform
>   frame sizes 0.970x for 4.7% fewer draws -- both nothing, which kills seed
>   bucketing by Overstock profile.
> - **No free scheduling wins left.** rare-before-uncommon 0.990x, split
>   rarity/edition 1.003x, packs hoisted across antes 1.011x.
> - **All fp64/RNG-core work is capped at 7.3%** of the pre-staging body
>   (register-pinned). Removing the ENTIRE RNG core buys 7.3%; the Tausworthe
>   warmup is 0.6%; `rng_advance_int` 7.2%; the exact fp64 bundle 2.9%.
>   Earlier unpinned numbers (18.5% / 7.1% / 3.8%) were a register-allocation
>   artifact -- see the measurement warning below.
> - `performance_todo` items 1, 2 and 4 are all closed: item 1 shipped as
>   `seedHashByLen`; item 2 is 0.14% of a seed; item 4 is a predicted net loss.
>   Item 3 (wr_filter dead draws) still stands.
> - An exact prefilter is impossible: the score is monotone in antes, so a prefix
>   is a lower bound (54.1% false negatives at antes 3-24).
>
> ## Still open
>
> - **Vouchers, ~10%.** No easy exact win found. One voucher per ante with a
>   strictly sequential resample chain, so there is no batch to densify and no
>   node state to hoist (every node is ante-keyed). The cost is node creation
>   plus divergence in a chain that cannot be reordered.
> - **Buffoon identities, ~66 draws/seed.** Must stay per-pack: a card is
>   temporarily locked while later cards in the SAME pack are drawn, so the
>   identity draws are sequentially dependent on lock state.
>
> ## Measurement warning
>
> Unpinned, this kernel's register allocation moves between 12/14/15/16 resident
> warps on almost any source edit, worth up to 12% -- larger than most effects
> being measured. It invalidated an entire ablation run (1 KB and 4 KB of ballast
> measured identically, as did 2 KB and 8 KB). The NVIDIA build now pins
> registers by default. Always check the `ctl-b / ctl-a` control pair reads
> 1.000x before believing anything else in a run.

Done first (2026-09-04): the RNG path no longer builds 260-byte `text` strings
(node names are streamed into the hash), and `i_new` became the in-place
`i_init` so the kernel frame holds one `instance` instead of two. On an RTX
5080, wr_filter went from 24.7 s to 4.0 s over 500M seeds with identical
output; `search` dropped from 255 registers / 51 KB frame / 8 KB spills to
131 registers / 34 KB / 0 spills, and `random` is inlined again. With
CACHE_SIZE 64 instead of 512 the same run is 3.4 s, so the 8.7 KB node cache
now costs about 15%, not the 6x it appeared to before. Other filters unchanged.

Analysis on 2026-09-03/04 identified these after the streaming node hash was
done. All were host-verified exact where noted; none has been measured on a GPU.

1. **Seed-suffix hash state cached by node-name length.** `pseudohash(name + seed)`
   consumes the seed first, but at positions offset by `len(name)`, so
   `hashedSeed` cannot be reused directly (verified: 200k/200k mismatches).
   Caching one state per distinct prefix length is exact (0/200k mismatches).
   Deep seeds use ~9 distinct lengths, so this removes ~95% of seed re-hashing
   on node creation. Deep-path gain est. 1.15-1.5x; no effect on shallow seeds.

2. **Hash-indexed node cache lookup.** `get_node_child` scans all live nodes
   linearly; one sampled deep seed did 973k 64-bit compares across 7.3k draws.
   A 128-bucket chained index (activated past ~32 nodes, full-key compare on
   hit) cuts that 65-95x. Exact. Deep-path only, est. 1.5-4x on lookup cost.

3. **wr_filter dead draws in antes 3-38.** `next_shop_item` draws tarot/planet
   identities for non-joker slots and polls stickers at White Stake where they
   cannot apply; both are independent RNG nodes the filter never reads.
   `wr_shop_joker` already does this for antes 1-2. ~24% of deep-path draws
   removable, exactly. Filter-local change.

4. **GF(2) jump-ahead for the 10-step LuaJIT warmup in `randomseed`.** The four
   Tausworthe words are independent and linear; a precomputed 10-step matrix per
   word (64 KB byte tables or 8 KB nibble tables in __constant) replaces 40
   shift/xor rounds. Verified exact on 4M state words. Est. 1.05-1.3x everywhere;
   highest complexity of the four, lowest payoff. Do last or not at all.
