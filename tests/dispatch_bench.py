#!/usr/bin/env python3
"""Immolate dispatch/launch-configuration diagnostics (RTX 5080 pack).

Standard library only. Run from the Immolate repository root:

    python3 tests/dispatch_bench.py <experiment>

The executable and the device's compute-unit count are discovered automatically;
pass --exe / --cu only to override them.

Timing methodology matches tests/common.py: wall clock (perf_counter) around the
whole process, one untimed warm-up so .kernel_cache is warm, median of --repeat
samples. Every experiment prints a ratio and the prediction it is testing.

Experiments
    calibrate   find a seed count that makes one DNS run last ~TARGET seconds
    g-sweep     A1: sweep -g (work-group count); the default is 16 per CU
    l-sweep     A2: sweep the local work-group size  (needs the diagnostic patch)
    regcap      B2: -cl-nv-maxrregcount sweep          (needs the diagnostic patch)
    saturation  D:  throughput vs -n, exposing an undersubscribed launch
    from-batch  E:  --from host-I/O serialisation, isolated by --batch size
    divergence  C:  cost-uniform pool vs natural pool
"""
import argparse, json, os, re, statistics, subprocess, sys, tempfile, time
from pathlib import Path

FILTER = "deep_negative_shops"
CUTOFF = "9223372036854775807"   # nothing prints; pure throughput


def find_executable(build_dir="build", cwd="."):
    """Locate the Immolate binary the way tests/run.py does.

    The default used to be the POSIX literal "./build/Immolate", which does not
    exist on Windows (CMake/MSVC puts it in build/Release/Immolate.exe) and made
    every experiment fail with "the system cannot find the file specified".
    """
    root = Path(cwd)
    candidates = [
        root / build_dir / "Immolate",
        root / build_dir / "Immolate.exe",
        root / build_dir / "Release" / "Immolate",
        root / build_dir / "Release" / "Immolate.exe",
        root / "build-pocl" / "Immolate",
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    tried = "\n  ".join(str(c) for c in candidates)
    sys.exit(f"could not find the Immolate executable. Tried:\n  {tried}\n"
             f"Build it first, or pass --exe explicitly.")


def detect_compute_units(exe, cwd, env, platform_id, device_id):
    """Read compute units out of --list_devices so --cu need not be passed."""
    try:
        p = subprocess.run([exe, "--list_devices"], cwd=cwd, env=env,
                           capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    current, want = None, (str(platform_id), str(device_id))
    for line in p.stdout.splitlines():
        m = re.fullmatch(r"Platform ID ([0-9]+), Device ID ([0-9]+)", line.strip())
        if m:
            current = m.groups()
            continue
        if current == want:
            m = re.fullmatch(r"Compute Units: ([0-9]+)", line.strip())
            if m:
                return int(m.group(1))
    return None


def run_once(exe, args, cwd, env):
    cmd = [exe] + [str(a) for a in args]
    t = time.perf_counter()
    p = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    return time.perf_counter() - t, p


def timed(exe, args, cwd, env, repeat, warm=1):
    for _ in range(warm):
        _, p = run_once(exe, args, cwd, env)
        if p.returncode != 0:
            return None, p
    s = []
    for _ in range(repeat):
        dt, p = run_once(exe, args, cwd, env)
        if p.returncode != 0:
            return None, p
        s.append(dt)
    return (statistics.median(s), min(s), max(s)), p


def base(a):
    return ["-p", a.platform, "-d", a.device, "-f", a.filter, "-s", a.seed, "-c", CUTOFF]


def calibrate(a, env):
    """Scale -n so a single run takes about a.target seconds.

    Never returns fewer than 8x the default launch width: below that the run is
    bound by the slowest single seed rather than by throughput (see D5 in the
    manifest), and every ratio measured there would be meaningless.
    """
    floor_n = a.cu * 16 * 32 * 8
    n = max(a.n_start, floor_n)
    dt = None
    # Untimed warm-up, matching timed(): without it the first probe on a cold
    # .kernel_cache pays the OpenCL kernel build (~24s for DNS on an RTX 5080),
    # which inflated a 8.24s probe to 32.24s and under-calibrated -n by ~4x.
    run_once(a.exe, base(a) + ["-n", floor_n, "--batch", a.batch], a.cwd, env)
    for _ in range(6):
        dt, p = run_once(a.exe, base(a) + ["-n", n, "--batch", a.batch], a.cwd, env)
        if p.returncode != 0:
            print(p.stdout[-2000:], p.stderr[-2000:]); sys.exit(1)
        body = dt - a.fixed
        if body > 0.35 * a.target:
            n = max(floor_n, int(n * a.target / body))
            break
        n *= 8
    print("calibrated -n %d  (last probe %.2fs, target %.1fs, saturation floor %d)"
          % (n, dt, a.target, floor_n))
    return n


def report(rows, baseline_label):
    width = max(len(r[0]) for r in rows) + 2
    b = dict((r[0], r[1]) for r in rows)[baseline_label]
    print()
    print("%-*s %10s %10s %10s %10s" % (width, "config", "median s", "min s", "max s", "vs base"))
    for label, med, lo, hi in rows:
        print("%-*s %10.4f %10.4f %10.4f %9.3fx" % (width, label, med, lo, hi, b / med))
    print("\n(vs base > 1.00 means FASTER than %s)" % baseline_label)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("experiment", choices=["calibrate", "g-sweep", "l-sweep", "regcap",
                                           "saturation", "from-batch", "divergence"])
    ap.add_argument("--exe", default=None,
                    help="path to the Immolate binary; found automatically if omitted")
    ap.add_argument("--build-dir", dest="build_dir", default="build")
    ap.add_argument("--cwd", default=".")
    ap.add_argument("--platform", default="0")
    ap.add_argument("--device", default="0")
    ap.add_argument("--filter", default=FILTER)
    ap.add_argument("--seed", default="11111111")
    ap.add_argument("--batch", default="1048576")
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("-n", dest="n", type=int, default=0, help="seed count; 0 = calibrate")
    ap.add_argument("--n-start", dest="n_start", type=int, default=20000)
    ap.add_argument("--target", type=float, default=6.0, help="seconds per run")
    ap.add_argument("--fixed", type=float, default=0.5, help="assumed fixed process overhead")
    ap.add_argument("--cu", type=int, default=0,
                    help="compute units; read from --list_devices if omitted (RTX 5080 = 84)")
    ap.add_argument("--pool-dir",
                    default=os.path.join(tempfile.gettempdir(), "immolate-dispatch"))
    a = ap.parse_args()
    env = dict(os.environ)

    if a.exe is None:
        a.exe = find_executable(a.build_dir, a.cwd)
    if a.cu <= 0:
        detected = detect_compute_units(a.exe, a.cwd, env, a.platform, a.device)
        if detected is None:
            sys.exit("could not read compute units from --list_devices; pass --cu explicitly "
                     "(RTX 5080 = 84).")
        a.cu = detected
    print(f"exe {a.exe}  |  compute units {a.cu}")

    if a.experiment == "calibrate":
        calibrate(a, env)
        return

    n = a.n or calibrate(a, env)

    if a.experiment == "g-sweep":
        # -g is TOTAL work-groups. Default = CU*16. With localSize 32 on NVIDIA
        # that is one warp per group, so k here is "warps per SM asked for".
        # k is capped at 32 on purpose. Lanes scale with k (cu*k*32), so with a
        # FIXED -n the high-k rows silently fall below one seed per lane and
        # degenerate into "slowest single seed" -- the same D5 pathology this
        # tool refuses to calibrate into, which would masquerade as an L2 cliff
        # and argue against the very hypothesis being tested. At k=32 and
        # n=344,064 every lane still gets 4 seeds. The range covers the
        # predicted efficiency peaks: k a multiple of W_res, i.e. 12/13/14 and
        # 24/26/28 for the 12-14 warps/SM that 137-154 registers imply.
        ks = [8, 12, 13, 14, 15, 16, 17, 18, 20, 24, 26, 28, 30, 32]
        lanes_at_max_k = a.cu * max(ks) * 32
        if n < 4 * lanes_at_max_k:
            print("note: -n %d gives only %.1f seeds/lane at k=%d; rows above k=%d are "
                  "tail-dominated and should be read with care."
                  % (n, n / lanes_at_max_k, max(ks), int(n / (4 * a.cu * 32))))
        rows = []
        for k in ks:
            g = a.cu * k
            r, p = timed(a.exe, base(a) + ["-n", n, "--batch", a.batch, "-g", g], a.cwd, env, a.repeat)
            if r is None:
                print("k=%d FAILED\n%s" % (k, p.stdout[-800:])); continue
            rows.append(("-g %d (%d/SM)" % (g, k), *r))
        report(rows, "-g %d (16/SM)" % (a.cu * 16))

    elif a.experiment == "l-sweep":
        rows = []
        for L in [32, 64, 128, 256]:
            # keep total lanes constant so only the group shape changes
            g = max(1, a.cu * 16 * 32 // L)
            r, p = timed(a.exe, base(a) + ["-n", n, "--batch", a.batch, "-g", g, "-l", L], a.cwd, env, a.repeat)
            if r is None:
                print("L=%d FAILED (likely CL_INVALID_WORK_GROUP_SIZE)\n%s" % (L, p.stdout[-800:])); continue
            note = " [DRIVER REJECTED, HALVED]" if "rejected by the driver" in p.stdout else ""
            rows.append(("-l %d -g %d%s" % (L, g, note), *r))
        if rows:
            report(rows, rows[0][0])

    elif a.experiment == "regcap":
        rows = []
        for cap in [0, 168, 160, 152, 144, 136, 128, 120, 112, 96]:
            extra = [] if cap == 0 else ["--build_opts", "-cl-nv-maxrregcount=%d" % cap]
            r, p = timed(a.exe, base(a) + ["-n", n, "--batch", a.batch] + extra, a.cwd, env, a.repeat)
            if r is None:
                print("cap=%s FAILED\n%s" % (cap, p.stdout[-800:])); continue
            rows.append(("maxrregcount=%s" % ("default" if cap == 0 else cap), *r))
        report(rows, "maxrregcount=default")

    elif a.experiment == "saturation":
        # Throughput (seeds/s) at counts around the default launch width.
        lanes = a.cu * 16 * 32
        rows = []
        print("default launch is %d work-items" % lanes)
        for cnt in [2048, lanes // 2, lanes, lanes * 4, lanes * 16, lanes * 64]:
            r, p = timed(a.exe, base(a) + ["-n", cnt, "--batch", a.batch], a.cwd, env, max(3, a.repeat // 2))
            if r is None:
                continue
            med = r[0]
            rows.append((cnt, med, cnt / max(med - a.fixed, 1e-9)))
        print("\n%12s %12s %16s %12s" % ("-n", "median s", "seeds/s (body)", "vs n=2048"))
        b = rows[0][2]
        for cnt, med, thr in rows:
            print("%12d %12.4f %16.1f %11.2fx" % (cnt, med, thr, thr / b))

    elif a.experiment == "from-batch":
        os.makedirs(a.pool_dir, exist_ok=True)
        pool = os.path.join(a.pool_dir, "dense.seeds")
        print("building a dense pool of %d consecutive ranks ..." % n)
        _, p = run_once(a.exe, ["-p", a.platform, "-d", a.device, "-f", "diag_disp_dns_cost_proxy",
                                "-s", a.seed, "-n", n, "-c", "0", "--to", pool, "--batch", a.batch], a.cwd, env)
        if p.returncode != 0:
            print(p.stdout[-2000:]); sys.exit(1)
        rows = []
        for bsz in [1048576, 65536, 16384, 4096]:
            r, p = timed(a.exe, base(a) + ["--from", pool, "-n", n, "--batch", bsz], a.cwd, env, a.repeat)
            if r is None:
                continue
            rows.append(("--from --batch %d" % bsz, *r))
        r, p = timed(a.exe, base(a) + ["-n", n, "--batch", a.batch], a.cwd, env, a.repeat)
        if r:
            rows.append(("range (no --from)", *r))
        report(rows, "--from --batch 1048576")

    elif a.experiment == "divergence":
        os.makedirs(a.pool_dir, exist_ok=True)
        mixed = os.path.join(a.pool_dir, "mixed.seeds")
        uni = os.path.join(a.pool_dir, "uniform.seeds")
        # A pool needs ~n seeds; the uniform bucket is ~35% of the range, so scan 4n.
        print("building pools from %d candidate seeds ..." % (n * 4))
        for flt, cut, out in (("diag_disp_dns_cost_proxy", "0", mixed),
                              ("diag_disp_dns_cost_proxy_neg", "-17910", uni)):
            _, p = run_once(a.exe, ["-p", a.platform, "-d", a.device, "-f", flt, "-s", a.seed,
                                    "-n", n * 4, "-c", cut, "--to", out, "--batch", a.batch], a.cwd, env)
            if p.returncode != 0:
                print(p.stdout[-2000:]); sys.exit(1)
        rows = []
        for label, pool in (("natural (mixed cost)", mixed), ("cost-uniform pool", uni)):
            r, p = timed(a.exe, base(a) + ["--from", pool, "-n", n, "--batch", a.batch], a.cwd, env, a.repeat)
            if r is None:
                continue
            rows.append((label, *r))
        report(rows, "natural (mixed cost)")


if __name__ == "__main__":
    main()
