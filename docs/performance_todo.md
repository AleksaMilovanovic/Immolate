# Performance follow-ups (not implemented)

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
