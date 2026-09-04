# Performance follow-ups (not implemented)

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
