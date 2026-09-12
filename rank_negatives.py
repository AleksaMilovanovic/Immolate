#!/usr/bin/env python3
"""Rank seeds from a deep_negative_shops run.

Reads Immolate's printed output ("SEED (score)" lines; other lines are
ignored), splits the score into its five 3-digit fields, and prints the top N
by a weighted total.

    immolate -f deep_negative_shops -c 0 --from pool.seeds > out.txt
    python rank_negatives.py out.txt
    python rank_negatives.py out.txt -n 50 --copy 25 --uncommon 5 --other 1

Score layout (see filters/deep_negative_shops.cl), high to low:
    copy | uncommon | other | first-tag negatives | second-tag negatives
Total = copy*W_COPY + uncommon*W_UNC + other*W_OTHER + tag1*W_TAG1 + tag2*W_TAG2
(defaults 25, 5, 0, 0, 0). Ties break on copy, then uncommon, then other.
"""
import argparse
import sys
import heapq


def parse(lines, get_total_value, max_rows):
    rows = []
    heapq.heapify(rows)
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
        tag2 = value % 1000; value //= 1000
        tag1 = value % 1000; value //= 1000
        other = value % 1000; value //= 1000
        unc = value % 1000; value //= 1000
        copy = value
        total = get_total_value((seed, copy, unc, other, tag1, tag2))
        if len(rows) >= max_rows:
            if total > rows[0][0]:
                heapq.heapreplace(rows, (total, seed, copy, unc, other, tag1, tag2))
        else:
            heapq.heappush(rows, (total, seed, copy, unc, other, tag1, tag2))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", help="Immolate output file (default: stdin)")
    ap.add_argument("-n", "--top", type=int, default=1000, help="how many to print (default 1000)")
    ap.add_argument("--copy", type=float, default=25, help="weight per negative copy joker (default 25)")
    ap.add_argument("--uncommon", type=float, default=5, help="weight per negative uncommon (default 5)")
    ap.add_argument("--other", type=float, default=0, help="weight per other negative / Diet Cola (default 0)")
    ap.add_argument("--tag1", type=float, default=0, help="weight per first-slot Negative Tag (default 0)")
    ap.add_argument("--tag2", type=float, default=0, help="weight per second-slot Negative Tag (default 0)")
    ap.add_argument("--csv", action="store_true", help="comma-separated output instead of aligned columns")
    a = ap.parse_args()

    src = open(a.file, encoding="utf-8", errors="replace") if a.file else sys.stdin
    get_total_value = lambda r: r[1] * a.copy + r[2] * a.uncommon + r[3] * a.other + r[4] * a.tag1 + r[5] * a.tag2
    rows = parse(src, get_total_value, a.n)
    if not rows:
        sys.exit("no 'SEED (score)' lines found")

    ranked = []
    for seed, copy, unc, other, tag1, tag2, total in rows:
        ranked.append((seed, copy, unc, other, tag1, tag2, total))
    # Primary key total, uncommon, copy, other; stable sort so ties keep file order.
    ranked.sort(key=lambda r: (r[6], r[2], r[1], r[3]), reverse=True)

    top = ranked[: a.top]
    if a.csv:
        print("seed,copy,uncommon,other,tag1,tag2,total")
        for r in top:
            print(",".join(str(x) for x in r))
    else:
        print(f"{'seed':<9} {'copy':>4} {'unc':>4} {'other':>5} {'tag1':>4} {'tag2':>4} {'total':>8}")
        for seed, copy, unc, other, tag1, tag2, total in top:
            t = f"{total:g}"
            print(f"{seed:<9} {copy:>4} {unc:>4} {other:>5} {tag1:>4} {tag2:>4} {t:>8}")
    print(f"# {len(top)} of {len(rows)} seeds", file=sys.stderr)


if __name__ == "__main__":
    main()
