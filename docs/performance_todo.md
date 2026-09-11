# Performance follow-ups (not implemented)

> **2026-09-11 status update — items 1, 2 and 4 below are now superseded by measurement.**
> Counts taken on `6d2c113` over 20,480 stratified seeds (see `docs/diagnostics.md`):
>
> - **Item 1 (seed-suffix hash cached by name length) is DONE** — it shipped as
>   `seedHashByLen`/`seedHashValid` in `lib/instance.cl`. Seed-suffix hashing is now
>   104 of 11,334 `ph_step` calls per DNS seed, i.e. **0.9%**. Nothing left here.
> - **Item 2 (hash-indexed node cache) should be CLOSED as done-by-other-means.** The MRU
>   `lastNode` hint, the reverse scan and `DNS_ANTE_LOCAL_CACHE` together cut key compares per
>   seed **1,693x** (32,593,876 -> 19,250). The linear scan is now **5.78 compares per lookup =
>   0.14% of a seed**; eliminating it entirely and for free would buy **1.0014x**. The 1.5-4x
>   estimate was sound against the code it was written for — an open-addressed prototype on that
>   older base measured **3.61x** — but the win is already banked.
> - **Item 4 (GF(2) jump-ahead for the warmup) is predicted a NET LOSS, not 1.05-1.3x.** The
>   estimate never priced the table lookups. The cheapest exact realisation (nibble tables for the
>   256->64 GF(2) map, 8 KB `__constant`) costs ~64 lookups + ~384 int32 per draw to remove 560
>   int32 — a net ALU saving of ~1.1-2.2% **before** the loads, and NVIDIA `__constant` reads with
>   lane-divergent addresses do not broadcast, they serialise up to 32-way. Byte tables are worse
>   (64 KB is the entire constant bank against an 8 KB per-SM constant cache).
> - **Item 3 (wr_filter dead draws) is untouched by this** — it is filter-local and still stands.
>
> Two related experiments were tried and reverted on the real 5080, and the current cost model
> predicts both outcomes: the software-binary64 `randomseed` (`git show aedde58:lib/rng_seed_soft.cl`)
> is a net **+7.8% cost** at realistic INT32 rates, and K=2 stream interleaving (`cf7b55e`) gains
> nothing in a throughput-bound kernel. A third, `lib/rng_advance_int.cl` (`git show
> 7264f38:lib/rng_advance_int.cl`), was reverted but per `git log` was **never benchmarked
> end-to-end**; `diag_rng_a3_intstate` bounds it in one run.

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
