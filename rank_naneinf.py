#!/usr/bin/env python3
"""Rank seeds from an analyze_naneinf_negatives run.

Reads Immolate's printed output ("SEED (score)" lines; other lines are ignored)
and prints the best seeds by score, highest first.

    immolate -f analyze_naneinf_negatives -c 1 --from pool.seeds > out.txt
    python3 rank_naneinf.py out.txt
    python3 rank_naneinf.py out.txt -n 50 --over-budget parked.txt

Two values are sentinels rather than scores, and both are listed separately:

  1000000000 + N  the seed offered N Negative Tags, more than
                  ANN_MAX_BRANCH_POINTS (10), so it was never searched. Rerun it
                  by hand with the cap raised:
                      immolate -f analyze_naneinf_explain -s SEED -n 1 -g 1 -c 0 \
                          --build_opts "-D ANN_MAX_BRANCH_POINTS=13"
  2000000000      the RNG node cache overflowed on this seed, so its score would
                  have been wrong and was withheld. The engine drew the Uncommon
                  pool down far enough to make the resample chains very deep.
                  Rerun those with a pool floor:
                      immolate -f analyze_naneinf_negatives --from pool.seeds \
                          --build_opts "-D ANN_LOCK_FLOOR=8"

Scores are the flat weighted total: 100 per negative Blueprint/Brainstorm, 5 per
negative Baron/Mime/Burglar/DNA, 1 per negative Juggler/Drunkard when the filter
was built with ANN_SCORE_COMMONS.
"""
import argparse
import sys

from immolate_text import read_lines

OVER_BUDGET = 1_000_000_000
CACHE_OVERFLOW = 2_000_000_000


def parse(lines):
    scored, parked, broken = [], [], []
    for line in lines:
        line = line.strip()
        sep = line.find(" (")
        if sep < 0 or not line.endswith(")"):
            continue  # header, progress, or warning line
        seed = line[:sep]
        try:
            value = int(line[sep + 2:-1])
        except ValueError:
            continue
        if value == CACHE_OVERFLOW:
            broken.append(seed)
        elif value >= OVER_BUDGET:
            parked.append((value - OVER_BUDGET, seed))
        else:
            scored.append((value, seed))
    return scored, parked, broken


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", help="Immolate output file (default: stdin)")
    ap.add_argument("-n", "--top", type=int, default=100, help="how many to print (default 100)")
    ap.add_argument("--over-budget", metavar="FILE",
                    help="write the unsearched seeds here instead of listing them")
    ap.add_argument("--csv", action="store_true", help="comma-separated output")
    a = ap.parse_args()

    scored, parked, broken = parse(read_lines(a.file))

    scored.sort(reverse=True)
    for value, seed in scored[:a.top]:
        print(f"{seed},{value}" if a.csv else f"{seed:<10} {value:>6}")

    parked.sort(reverse=True)
    if a.over_budget:
        with open(a.over_budget, "w") as fh:
            for points, seed in parked:
                fh.write(f"{seed} {points}\n")
        if parked:
            print(f"\n{len(parked)} seed(s) over the branch-point budget -> {a.over_budget}",
                  file=sys.stderr)
    elif parked:
        print(f"\nover budget, never searched ({len(parked)}):", file=sys.stderr)
        for points, seed in parked:
            print(f"{seed:<10} {points} branch points", file=sys.stderr)

    if broken:
        print(f"\nnode cache overflowed, score withheld ({len(broken)}): "
              f"rerun with -D ANN_LOCK_FLOOR=8", file=sys.stderr)
        for seed in broken:
            print(f"{seed}", file=sys.stderr)


if __name__ == "__main__":
    main()
