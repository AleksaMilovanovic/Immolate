#!/usr/bin/env python3
"""Sequential kernel-profiling driver for Immolate (see docs/kernel_profile.md).

Usage: python tests/profile_kernel.py tests/kernel_profile/<plan>.json
Run the plans in order (primitives, followup, dns_fixed). Nothing else may use
the GPU while a plan runs; REPEATS and TARGET_S can be set in the environment.

Modes (chosen per plan entry with "mode"):
  bench    - warm-up, then adapt -n so a run lasts ~TARGET_S, then REPEATS timed
             runs. Keeps both the process's own "Done in" seconds (kernel enqueue
             to context release) and the external process wall time.
  counters - run a diag_count_* wrapper with --scores_to and average the two
             32-bit counters packed in every score.
  regs     - --verbose_build with -n 1; capture ptxas register/stack/spill lines.
Results are appended to results.json after every entry.
"""
import json, os, re, subprocess, sys, time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "build" / "Release" / "Immolate.exe"
CACHE = REPO / ".kernel_cache"
HERE = Path(__file__).parent / "kernel_profile"
OUT = Path(os.environ.get("PROFILE_OUT", HERE / "results.json"))
SEED = "1111111H"  # rank 66231629152, a multiple of 32
REPEATS = int(os.environ.get("REPEATS", "3"))
TARGET_S = float(os.environ.get("TARGET_S", "1.6"))
sys.path.insert(0, str(REPO / "tests"))
from common import iter_score_values  # noqa: E402

def run(argv, timeout=1800):
    t0 = time.perf_counter_ns()
    p = subprocess.run(argv, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    wall = (time.perf_counter_ns() - t0) / 1e9
    m = re.search(r"Done in ([0-9.]+)s", p.stdout)
    done = float(m.group(1)) if m else None
    if p.returncode != 0 or done is None:
        raise RuntimeError(f"{argv}\nrc={p.returncode}\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}")
    if "cache overflow" in p.stdout:
        raise RuntimeError(f"cache overflow in {argv}")
    return done, wall, p.stdout, p.stderr

def cache_files():
    return {f.name for f in CACHE.glob("*.bin")}

def load():
    return json.loads(OUT.read_text()) if OUT.exists() else {}

def save(res):
    OUT.write_text(json.dumps(res, indent=1))

def base_argv(entry, n, cutoff):
    argv = [str(EXE), "-f", entry["filter"], "-s", entry.get("seed", SEED), "-n", str(n), "-c", str(cutoff)]
    if entry.get("build_opts"):
        argv += ["--build_opts", entry["build_opts"]]
    argv += entry.get("args", [])
    return argv

def bench(entry):
    n = int(entry["n"])
    argv = base_argv(entry, n, entry.get("cutoff", 999999999))
    before = cache_files()
    t0 = time.perf_counter()
    wd, ww, so, se = run(argv)
    warm = time.perf_counter() - t0
    new = [k for k in cache_files() if k not in before]
    compiled = "Saved compiled kernel to cache" in so
    # Adapt n so the timed runs last about TARGET_S (never shrink below the plan's n/4).
    if not entry.get("fixed_n"):
        est = wd if wd > 0.02 else 0.02
        n2 = int(n * TARGET_S / est)
        n2 = max(n // 4, min(n2, 4_000_000_000))
        n2 = (n2 // 43008) * 43008 or 43008  # whole waves of the default launch
        if abs(n2 - n) / n > 0.15:
            n = n2
            argv = base_argv(entry, n, entry.get("cutoff", 999999999))
            wd, ww, _, _ = run(argv)  # re-warm at the final size
    dones, walls = [], []
    for _ in range(REPEATS):
        d, w, _, _ = run(argv)
        dones.append(d); walls.append(w)
    ds = sorted(dones); ws = sorted(walls)
    return {
        "mode": "bench", "filter": entry["filter"], "build_opts": entry.get("build_opts"), "n": n, "args": entry.get("args", []),
        "done_s": dones, "wall_s": walls, "done_median": ds[len(ds)//2], "wall_median": ws[len(ws)//2], "done_min": ds[0],
        "spread_pct": (ds[-1] - ds[0]) / ds[len(ds)//2] * 100, "warmup_wall": warm, "compiled": compiled,
        "cache_bin": new[0] if new else None, "seeds_per_s": n / ds[len(ds)//2], "ns_per_seed": ds[len(ds)//2] / n * 1e9,
    }

def counters(entry):
    n = int(entry["n"])
    path = HERE / f"{entry['label']}.scores"
    if path.exists():
        path.unlink()
    argv = base_argv(entry, n, 0) + ["--scores_to", str(path)]
    before = cache_files()
    wd, ww, so, se = run(argv)
    new = [k for k in cache_files() if k not in before]
    header, values = iter_score_values(path)
    hi_sum = lo_sum = 0; hi_max = lo_max = 0; cnt = 0
    for v in values:
        hi = (v >> 32) & 0xFFFFFFFF; lo = v & 0xFFFFFFFF
        hi_sum += hi; lo_sum += lo; hi_max = max(hi_max, hi); lo_max = max(lo_max, lo); cnt += 1
    return {"mode": "counters", "filter": entry["filter"], "build_opts": entry.get("build_opts"), "n": cnt,
            "hi_mean": hi_sum / cnt, "lo_mean": lo_sum / cnt, "hi_max": hi_max, "lo_max": lo_max,
            "cache_bin": new[0] if new else None, "done_s": wd}

def regs(entry):
    argv = base_argv(entry, 1, entry.get("cutoff", 999999999)) + ["--verbose_build"]
    t0 = time.perf_counter()
    p = subprocess.run(argv, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=1800)
    wall = time.perf_counter() - t0
    log = p.stdout + "\n" + p.stderr
    lines = [l.strip() for l in log.splitlines() if "ptxas" in l or "Function properties" in l or "bytes stack" in l or "registers" in l.lower()]
    return {"mode": "regs", "filter": entry["filter"], "build_opts": entry.get("build_opts"), "rc": p.returncode,
            "compile_wall": wall, "lines": lines, "raw_tail": log[-6000:]}

def profile(plan):
    res = load()
    for entry in plan:
        label = entry["label"]
        if label in res and not entry.get("force"):
            print(f"skip {label}", flush=True)
            continue
        try:
            mode = entry.get("mode", "bench")
            rec = {"bench": bench, "counters": counters, "regs": regs}[mode](entry)
        except Exception as exc:  # keep going; record the failure
            rec = {"mode": entry.get("mode", "bench"), "filter": entry["filter"], "error": str(exc)[:4000]}
            print(f"FAIL {label}: {str(exc)[:600]}", flush=True)
        res[label] = rec
        save(res)
        if rec.get("mode") == "bench" and "error" not in rec:
            print(f"{label:36s} n={rec['n']:>11d} done={rec['done_median']:.4f}s wall={rec['wall_median']:.4f}s "
                  f"{rec['ns_per_seed']:9.3f} ns/seed spread={rec['spread_pct']:.1f}% "
                  f"{'COMPILED' if rec['compiled'] else 'cached'} {rec['cache_bin']}", flush=True)
        elif rec.get("mode") == "counters" and "error" not in rec:
            print(f"{label:36s} n={rec['n']} hi_mean={rec['hi_mean']:.3f} lo_mean={rec['lo_mean']:.3f} "
                  f"hi_max={rec['hi_max']} lo_max={rec['lo_max']}", flush=True)
        elif rec.get("mode") == "regs" and "error" not in rec:
            print(f"{label:36s} compile={rec['compile_wall']:.1f}s rc={rec['rc']} lines={len(rec['lines'])}", flush=True)
    return res

if __name__ == "__main__":
    plan = json.loads(Path(sys.argv[1]).read_text())
    profile(plan)
    print("PLAN COMPLETE", flush=True)
