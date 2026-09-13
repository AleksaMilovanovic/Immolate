#!/usr/bin/env python3
"""Bucket an ANN_BRANCH_POINTS probe run by branch-point count.

    immolate -f analyze_naneinf_negatives --from pool.txt -c 0 \
        --build_opts "-D ANN_BRANCH_POINTS" > probe.txt
    python3 branch_histogram.py probe.txt

Search cost is roughly 3^M leaves for a seed with M branch points, so a pool's
runtime is set by its worst few percent rather than by its median. The "share of
work" column is what each bucket actually costs. A score of 1000000000 + M is a
seed parked for exceeding ANN_MAX_BRANCH_POINTS; M is still its true count.
"""
import sys
import collections

OVER = 1_000_000_000


def main():
    scored, parked = collections.Counter(), collections.Counter()
    src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
    with src as fh:
        for line in fh:
            line = line.strip()
            i = line.find(" (")
            if i < 0 or not line.endswith(")"):
                continue
            try:
                v = int(line[i + 2:-1])
            except ValueError:
                continue
            (parked if v >= OVER else scored)[v - OVER if v >= OVER else v] += 1

    total = sum(scored.values()) + sum(parked.values())
    if not total:
        print("no probe lines found", file=sys.stderr)
        return 1
    work = {m: c * 3 ** m for m, c in scored.items()}
    tw = sum(work.values()) or 1
    print(f"{total} seeds\n")
    print(f"{'M':>3}  {'seeds':>7}  {'share':>7}  {'~leaves':>10}  {'share of work':>14}")
    for m in sorted(scored):
        print(f"{m:>3}  {scored[m]:>7}  {100*scored[m]/total:>6.2f}%  {3**m:>10,}  {100*work[m]/tw:>13.1f}%")
    for m in sorted(parked):
        print(f"{m:>3}  {parked[m]:>7}  {100*parked[m]/total:>6.2f}%  {3**m:>10,}   PARKED (over cap)")

    heavy = sum(c for m, c in scored.items() if m >= 8)
    hw = sum(w for m, w in work.items() if m >= 8)
    if heavy:
        print(f"\nM>=8: {heavy} seeds ({100*heavy/total:.1f}%) doing {100*hw/tw:.0f}% of the work")
    if parked:
        print(f"parked: {sum(parked.values())} seeds; rerun just those with "
              f"-D ANN_MAX_BRANCH_POINTS={max(parked)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
