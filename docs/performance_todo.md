# Performance follow-ups (not implemented)

> **2026-09-11 RESULTS — measured on an RTX 5080, 344,064 seeds of deep_negative_shops.**
> Two changes landed, together **2.812x** (8.577s -> 3.050s; 40,115 -> 112,808 seeds/s).
> Both bit-exact, verified by exact-score comparison.
>
> | change | speedup |
> |---|---|
> | `dns_staged_resample`: depth-major identity resamples, 128-slot staging chunk | 2.076x |
> | `-cl-nv-maxrregcount=128` on NVIDIA (12-14 -> 16 resident warps) | 1.390x |
> | **combined (97.4% composition efficiency)** | **2.812x** |
>
> **Measured ceilings — these close most of the list below.** From ablation fixtures,
> `ceiling = (1 - ratio) / 0.941`:
>
> | ablation | ratio | ceiling |
> |---|---|---|
> | remove the ENTIRE RNG core | 0.815 | **19.7%** |
> | remove `roundDigits` | 0.886 | 12.1% |
> | remove the 10-round Tausworthe warmup | 0.929 | **7.5%** |
> | integer node recurrence (`rng_advance_int`) | 0.964 | **3.8%** |
> | remove the lock/resample machinery | 0.233 | **81.5%** |
>
> The last row is why the staging change was the win: the resample loops are 4.9% of
> draws and 77% of runtime. Everything fp64 is capped at 19.7% *in total*.
>
> - **Item 1 is DONE** (shipped as `seedHashByLen`; seed-suffix hashing is 104 of 11,334
>   `ph_step` calls = 0.9%).
> - **Item 2 is CLOSED as done-by-other-means** — the linear scan is 5.78 compares per
>   lookup = 0.14% of a seed. The MRU hint, reverse scan and `DNS_ANTE_LOCAL_CACHE` cut key
>   compares 1,693x (32,593,876 -> 19,250).
> - **Item 4 is CLOSED as a net loss.** Measured ceiling 7.5%, and the cheapest exact
>   realisation costs ~64 `__constant` lookups + ~384 int32 per draw to remove 560 int32 --
>   and NVIDIA `__constant` reads with lane-divergent addresses serialise up to 32-way.
> - **Item 3 (wr_filter dead draws) is untouched** and still stands.
>
> Also closed by measurement: the software-binary64 `randomseed` (`aedde58`) is a net +7.8%
> cost; K=2 stream interleaving (`cf7b55e`) is flat (the K=1..8 ILP probe showed no latency
> bound, so extra ILP buys nothing); an exact prefilter is impossible (the score is monotone
> in antes, so a prefix is a lower bound -- 54.1% false negatives at antes 3-24); seed-level
> work redistribution has a 9.4% oracle ceiling; `--from` host I/O is a 0.2% stall.
>
> **Measurement warning.** Unpinned, this kernel's register allocation moves between 12, 14,
> 15 and 16 resident warps on almost any source edit, worth up to ~12%. That swamped the
> footprint sweep (1 KB and 4 KB of ballast measured identically, as did 2 KB and 8 KB) and
> made small ablations unreadable. **Pin `-cl-nv-maxrregcount` before trusting any A/B below
> ~12%** -- which the shipped build now does on NVIDIA by default.

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
