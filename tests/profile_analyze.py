#!/usr/bin/env python3
"""Turn tests/kernel_profile/results.json (from profile_kernel.py) into the cost-model tables of docs/kernel_profile.md."""
import json, sys
from pathlib import Path

import os
R = json.loads(Path(os.environ.get("PROFILE_OUT", Path(__file__).parent / "kernel_profile" / "results.json")).read_text())

def ns(label):
    return R[label]["ns_per_seed"]

def slope(kind, k1, k2, per=1):
    a, b = f"prim_{kind}_K{k1}", f"prim_{kind}_K{k2}"
    if a not in R or b not in R or "error" in R[a] or "error" in R[b]:
        return None
    return (ns(b) - ns(a)) / ((k2 - k1) * per)

print("=== per-seed floor ===")
print(f"prim_empty (s_from_rank + i_init + loop): {ns('prim_empty'):.3f} ns/seed  -> {R['prim_empty']['seeds_per_s']/1e6:.0f} M seeds/s")

print("\n=== primitive unit costs (slope between two K values, ns per repetition) ===")
fma = slope("dfma_peak", 64, 256, per=8)
fma_dep = slope("dfma_dep", 64, 256, per=8)
imad = slope("imad_peak", 64, 256, per=8)
i64 = slope("i64_taus", 64, 256)
rows = [
    ("fp64 FMA, 8 independent chains (pipe throughput)", fma),
    ("fp64 FMA, 1 dependent chain (latency exposure)", fma_dep),
    ("int32 IMAD, 8 independent chains", imad),
    ("one Tausworthe word step (int64 shifts/xors)", i64),
    ("fract(h*a+b): mul, add, floor, sub", slope("fract", 32, 128)),
    ("cvt f64->s64->f64 + mul, mul, add", slope("cvt64", 32, 128)),
    ("div_pos (+fract, mul, add)", slope("divpos", 32, 128)),
    ("ph_step (one hashed character)", slope("phstep", 32, 128)),
    ("rng_node_advance on a register (fract + roundDigits + /2)", slope("advance", 32, 128)),
    ("randomseed fp64 seeding only + 1 draw (no warmup)", slope("rsfp", 32, 128)),
    ("randomseed full (seeding + 10 warmup) + 1 draw", slope("randomseed", 32, 128)),
    ("11 Tausworthe steps on register state", slope("taus", 32, 128)),
    ("full draw, register state (advance+randomseed+randint+const)", slope("draw_reg", 32, 128)),
    ("full draw, production path on one cached node", slope("draw_inst", 32, 128)),
    ("get_node_child, lastNode hit (advance in local mem)", slope("node_hit", 32, 128)),
    ("node creation (scan miss + name hash), scan grows", slope("node_create", 32, 128)),
    ("node creation, cache emptied each time (no scan)", slope("node_create_reset", 32, 128)),
    ("lookup that walks ~31 keys then advances", slope("node_scan", 32, 128)),
    ("dependent __constant load, divergent addresses", slope("const_div", 32, 128)),
    ("dependent __constant load, uniform addresses", slope("const_uni", 32, 128)),
    ("dependent local-memory load+store pair", slope("local", 32, 128)),
    ("s_from_rank (eight 64-bit divides by 35)", slope("sfromrank", 8, 32)),
]
for name, v in rows:
    if v is None:
        print(f"  {name:64s}  n/a"); continue
    eq = f"{v/fma:6.1f} fp64-op equivalents" if fma else ""
    print(f"  {name:64s} {v*1000:9.2f} ps  {eq}")

print("\n=== divergence probes (ns/seed; ratio vs control) ===")
for name in ("erratic", "bb", "wr", "negtags", "dns"):
    ctl = R.get(f"uni_{name}_ctl"); warp = R.get(f"uni_{name}_warp"); launch = R.get(f"uni_{name}_launch"); plain = R.get(f"uni_{name}_plain")
    if not ctl or "error" in ctl: print(f"  {name}: missing"); continue
    c = ctl["ns_per_seed"]
    s = f"  {name:8s} plain={plain['ns_per_seed'] if plain and 'error' not in plain else float('nan'):9.3f}  ctl={c:9.3f}"
    if warp and "error" not in warp: s += f"  warp-uniform={warp['ns_per_seed']:9.3f} ({warp['ns_per_seed']/c:.3f}x)"
    if launch and "error" not in launch: s += f"  launch-uniform={launch['ns_per_seed']:9.3f} ({launch['ns_per_seed']/c:.3f}x)"
    print(s)

print("\n=== dynamic operation counts per seed (means) ===")
names = ["nodeResolve", "nodeCreate", "lastHit", "scanCmp", "advance", "reseed", "draw", "phName", "phSeed", "phInit"]
counts = {}
for name in ("erratic", "bb", "wr", "negtags", "dns"):
    c = {}
    for pair in range(5):
        rec = R.get(f"count_{name}_p{pair}")
        if not rec or "error" in rec: continue
        c[names[2*pair]] = rec["hi_mean"]; c[names[2*pair+1]] = rec["lo_mean"]
    counts[name] = c
hdr = f"  {'filter':8s}" + "".join(f"{n:>12s}" for n in names)
print(hdr)
for name, c in counts.items():
    print(f"  {name:8s}" + "".join(f"{c.get(n, float('nan')):12.1f}" for n in names))

print("\n=== cost model: predicted ns/seed from counts x unit costs vs measured (control probe) ===")
ph = slope("phstep", 32, 128); drw = slope("draw_inst", 32, 128); adv = slope("node_hit", 32, 128); rs = slope("randomseed", 32, 128) - slope("rsfp", 32, 128) if slope("rsfp",32,128) else 0
floor = ns("prim_empty")
print(f"  unit costs used: ph_step={ph*1000:.1f} ps, draw(advance+reseed)={drw*1000:.1f} ps, advance-only={adv*1000:.1f} ps, floor={floor:.3f} ns (includes the 8 ph_steps of i_init)")
for name, c in counts.items():
    ctl = R.get(f"uni_{name}_ctl")
    if not c or not ctl or "error" in ctl: continue
    # the control probe pays i_init twice (one extra seed hash of 8 ph_steps) plus s_tell/s_from_rank
    hash_ns = (c["phName"] + c["phSeed"]) * ph
    reseed_draws = c["reseed"]
    extra_draws = max(0.0, c["draw"] - c["reseed"])  # draws without a reseed (deck shuffle)
    adv_only = max(0.0, c["advance"] - c["reseed"])
    draw_ns = reseed_draws * drw + adv_only * adv + extra_draws * i64 * 1.5
    pred = floor + 8 * ph + hash_ns + draw_ns
    meas = ctl["ns_per_seed"]
    print(f"  {name:8s} measured={meas:9.3f}  predicted={pred:9.3f} ({pred/meas*100:5.1f}%)   "
          f"of which: floor+2nd init={floor+8*ph:6.3f}  name hashing={hash_ns:7.3f} ({hash_ns/meas*100:4.1f}%)  draws={draw_ns:7.3f} ({draw_ns/meas*100:4.1f}%)  unexplained={meas-pred:7.3f} ({(meas-pred)/meas*100:4.1f}%)")

print("\n=== register / stack reports (search kernel) ===")
for k, v in R.items():
    if v.get("mode") == "regs":
        lines = [l for l in v.get("lines", []) if "search" in l or "Used" in l or "stack" in l or "spill" in l]
        print(f"  {k}: compile {v.get('compile_wall',0):.1f}s")
        for l in v.get("lines", [])[:40]:
            print("     ", l)

print("\n=== host overhead: process wall minus in-process time ===")
d = [(v["wall_median"] - v["done_median"]) for v in R.values() if v.get("mode") == "bench" and "error" not in v]
if d:
    d.sort(); print(f"  median {d[len(d)//2]*1000:.0f} ms, min {d[0]*1000:.0f} ms, max {d[-1]*1000:.0f} ms over {len(d)} runs")
