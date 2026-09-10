#!/usr/bin/env python3
"""Compare Immolate suite runs and canonical artifacts."""

from __future__ import annotations

import argparse
import difflib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from common import (
    FormatError,
    compare_score_files,
    load_json,
    normalize_snapshot,
    rank_to_seed,
    read_supplier,
    write_json,
)


def limited(values: list, max_examples: int | None) -> list:
    return values if max_examples is None else values[:max_examples]


def compare_record_documents(left: dict, right: dict, max_examples: int | None) -> dict:
    left_records = {int(record["rank"]): int(record["score"]) for record in left.get("records", [])}
    right_records = {int(record["rank"]): int(record["score"]) for record in right.get("records", [])}
    missing = sorted(left_records.keys() - right_records.keys())
    extra = sorted(right_records.keys() - left_records.keys())
    changed = [rank for rank in sorted(left_records.keys() & right_records.keys()) if left_records[rank] != right_records[rank]]
    return {
        "type": "score_records",
        "equal": not missing and not extra and not changed,
        "missing_count": len(missing),
        "extra_count": len(extra),
        "score_mismatch_count": len(changed),
        "missing": [{"rank": rank, "seed": rank_to_seed(rank), "score": left_records[rank]} for rank in limited(missing, max_examples)],
        "extra": [{"rank": rank, "seed": rank_to_seed(rank), "score": right_records[rank]} for rank in limited(extra, max_examples)],
        "score_mismatches": [
            {
                "rank": rank,
                "seed": rank_to_seed(rank),
                "left": left_records[rank],
                "right": right_records[rank],
            }
            for rank in limited(changed, max_examples)
        ],
    }


def compare_snapshots(left: str, right: str) -> dict:
    left_lines = left.splitlines()
    right_lines = right.splitlines()
    diff = list(
        difflib.unified_diff(
            left_lines,
            right_lines,
            fromfile="left",
            tofile="right",
            lineterm="",
            n=3,
        )
    )
    first = None
    shared = min(len(left_lines), len(right_lines))
    for index in range(shared):
        if left_lines[index] != right_lines[index]:
            first = index + 1
            break
    if first is None and len(left_lines) != len(right_lines):
        first = shared + 1
    return {
        "type": "snapshot",
        "equal": not diff,
        "first_differing_line": first,
        "diff": diff,
    }


def compare_supplier_documents(left: dict, right: dict, max_examples: int | None) -> dict:
    left_header = left.get("header", {})
    right_header = right.get("header", {})
    header_differences = {
        key: {"left": left_header.get(key), "right": right_header.get(key)}
        for key in sorted(set(left_header) | set(right_header))
        if left_header.get(key) != right_header.get(key)
    }
    left_ranks = set(int(rank) for rank in left.get("ranks", []))
    right_ranks = set(int(rank) for rank in right.get("ranks", []))
    missing = sorted(left_ranks - right_ranks)
    extra = sorted(right_ranks - left_ranks)
    return {
        "type": "supplier",
        "equal": not header_differences and not missing and not extra,
        "header_differences": header_differences,
        "missing_count": len(missing),
        "extra_count": len(extra),
        "missing": [{"rank": rank, "seed": rank_to_seed(rank)} for rank in limited(missing, max_examples)],
        "extra": [{"rank": rank, "seed": rank_to_seed(rank)} for rank in limited(extra, max_examples)],
    }


def compare_hash_documents(left: dict, right: dict, max_examples: int | None) -> dict:
    metadata_fields = ("algorithm", "case_id", "case_sha256", "filter", "start_rank", "count", "block_size")
    metadata_differences = {
        field: {"left": left.get(field), "right": right.get(field)}
        for field in metadata_fields
        if left.get(field) != right.get(field)
    }
    left_blocks = {(int(block["start_rank"]), int(block["count"])): block["sha256"] for block in left.get("blocks", [])}
    right_blocks = {(int(block["start_rank"]), int(block["count"])): block["sha256"] for block in right.get("blocks", [])}
    block_keys = sorted(set(left_blocks) | set(right_blocks))
    changed = [key for key in block_keys if left_blocks.get(key) != right_blocks.get(key)]
    examples = []
    for start, count in limited(changed, max_examples):
        examples.append({
            "start_rank": start,
            "end_rank": start + count - 1,
            "start_seed": rank_to_seed(start),
            "end_seed": rank_to_seed(start + count - 1),
            "count": count,
            "left": left_blocks.get((start, count)),
            "right": right_blocks.get((start, count)),
        })
    return {
        "type": "score_hashes",
        "equal": not metadata_differences and not changed and left.get("whole_sha256") == right.get("whole_sha256"),
        "metadata_differences": metadata_differences,
        "whole_sha256": {"left": left.get("whole_sha256"), "right": right.get("whole_sha256")},
        "changed_block_count": len(changed),
        "changed_blocks": examples,
    }


def compare_canonical(left: dict, right: dict, max_examples: int | None) -> dict:
    left_type = left.get("type") or left.get("format")
    right_type = right.get("type") or right.get("format")
    if left_type != right_type:
        return {"type": "type_mismatch", "equal": False, "left": left_type, "right": right_type}
    if left_type in ("score_records", "immolate-score-records-v1"):
        return compare_record_documents(left, right, max_examples)
    if left_type == "snapshot":
        return compare_snapshots(str(left.get("text", "")), str(right.get("text", "")))
    if left_type == "supplier":
        return compare_supplier_documents(left, right, max_examples)
    if left_type in ("score_hashes", "immolate-score-hashes-v1"):
        return compare_hash_documents(left, right, max_examples)
    equal = left == right
    return {"type": left_type or "json", "equal": equal, "left": left if not equal else None, "right": right if not equal else None}


def canonical_supplier(path: Path) -> dict:
    header, ranks = read_supplier(path)
    return {
        "type": "supplier",
        "header": {
            "filter": header.filter,
            "cutoff": header.cutoff,
            "start_rank": header.start_rank,
            "num_seeds": header.num_seeds,
            "flags": header.flags,
            "count": header.count,
        },
        "ranks": ranks,
    }


def detect_file(path: Path) -> tuple[str, Any]:
    if path.suffix == ".scores":
        return "score_file", path
    raw = path.read_bytes()[:116]
    if raw.startswith(b"IMMSCORE"):
        return "score_file", path
    if raw.startswith(b"IMMSEEDS"):
        return "canonical", canonical_supplier(path)
    if path.suffix == ".json":
        return "canonical", load_json(path)
    return "canonical", {"type": "snapshot", "text": normalize_snapshot(path.read_text(encoding="utf-8"))}


def find_score_file(case_dir: Path) -> Path | None:
    candidates = sorted(case_dir.glob("*.scores"))
    return candidates[0] if len(candidates) == 1 else None


def compare_case_dirs(left: Path, right: Path, max_examples: int | None) -> dict:
    left_canonical = left / "canonical.json"
    right_canonical = right / "canonical.json"
    if not left_canonical.exists() or not right_canonical.exists():
        return {"type": "missing_canonical", "equal": False, "left_exists": left_canonical.exists(), "right_exists": right_canonical.exists()}
    result = compare_canonical(load_json(left_canonical), load_json(right_canonical), max_examples)
    left_score = find_score_file(left)
    right_score = find_score_file(right)
    if left_score and right_score:
        exact = compare_score_files(left_score, right_score, max_examples=max_examples)
        result["exact_scores"] = exact
        result["equal"] = bool(result.get("equal")) and bool(exact.get("equal"))
    return result


def compare_runs(left: Path, right: Path, max_examples: int | None) -> dict:
    left_cases_dir = left / "cases"
    right_cases_dir = right / "cases"
    if not left_cases_dir.is_dir() or not right_cases_dir.is_dir():
        raise FormatError("run directories must contain cases/")
    left_cases = {path.name: path for path in left_cases_dir.iterdir() if path.is_dir()}
    right_cases = {path.name: path for path in right_cases_dir.iterdir() if path.is_dir()}
    missing = sorted(left_cases.keys() - right_cases.keys())
    extra = sorted(right_cases.keys() - left_cases.keys())
    cases: dict[str, dict] = {}
    for case_id in sorted(left_cases.keys() & right_cases.keys()):
        cases[case_id] = compare_case_dirs(left_cases[case_id], right_cases[case_id], max_examples)

    timing: dict[str, dict] = {}
    for case_id in sorted(left_cases.keys() & right_cases.keys()):
        left_metrics_path = left_cases[case_id] / "metrics.json"
        right_metrics_path = right_cases[case_id] / "metrics.json"
        if not left_metrics_path.exists() or not right_metrics_path.exists():
            continue
        left_metrics = load_json(left_metrics_path)
        right_metrics = load_json(right_metrics_path)
        left_median = left_metrics.get("timing", {}).get("median_seconds")
        right_median = right_metrics.get("timing", {}).get("median_seconds")
        if left_median is None or right_median is None:
            continue
        timing[case_id] = {
            "left_median_seconds": left_median,
            "right_median_seconds": right_median,
            "ratio": right_median / left_median if left_median else None,
            "delta_seconds": right_median - left_median,
        }

    equal = not missing and not extra and all(case.get("equal", False) for case in cases.values())
    return {
        "format": "immolate-run-diff-v1",
        "equal": equal,
        "left": str(left),
        "right": str(right),
        "missing_cases": missing,
        "extra_cases": extra,
        "cases": cases,
        "timing": timing,
    }


def compare_paths(left: Path, right: Path, max_examples: int | None) -> dict:
    if left.is_dir() and right.is_dir():
        if (left / "cases").is_dir() or (right / "cases").is_dir():
            return compare_runs(left, right, max_examples)
        return compare_case_dirs(left, right, max_examples)
    if left.is_dir() != right.is_dir():
        raise FormatError("cannot compare a directory with a file")
    left_type, left_value = detect_file(left)
    right_type, right_value = detect_file(right)
    if left_type != right_type:
        return {"format": "immolate-artifact-diff-v1", "equal": False, "type_mismatch": {"left": left_type, "right": right_type}}
    if left_type == "score_file":
        return compare_score_files(left_value, right_value, max_examples=max_examples)
    return compare_canonical(left_value, right_value, max_examples)


def format_report(result: dict) -> str:
    lines = ["Immolate comparison", f"Correctness: {'equal' if result.get('equal') else 'DIFFERENT'}"]
    if result.get("missing_cases"):
        lines.append("Missing cases: " + ", ".join(result["missing_cases"]))
    if result.get("extra_cases"):
        lines.append("Extra cases: " + ", ".join(result["extra_cases"]))

    cases = result.get("cases", {})
    for case_id, case in cases.items():
        marker = "PASS" if case.get("equal") else "DIFF"
        lines.append(f"[{marker}] {case_id}")
        if case.get("changed_block_count"):
            lines.append(f"  changed hash blocks: {case['changed_block_count']}")
        if case.get("missing_count"):
            lines.append(f"  missing ranks: {case['missing_count']}")
        if case.get("extra_count"):
            lines.append(f"  extra ranks: {case['extra_count']}")
        if case.get("score_mismatch_count"):
            lines.append(f"  score mismatches: {case['score_mismatch_count']}")
        exact = case.get("exact_scores")
        if exact and exact.get("different_scores"):
            lines.append(f"  exact score mismatches: {exact['different_scores']}")
            for example in exact.get("examples", []):
                lines.append(
                    f"    {example['left_rank']} / {example['left_seed'] or '<empty>'}: "
                    f"{example['left_score']} -> {example['right_score']}"
                )
        for example in case.get("score_mismatches", []):
            lines.append(f"    {example['rank']} / {example['seed'] or '<empty>'}: {example['left']} -> {example['right']}")
        if case.get("first_differing_line"):
            lines.append(f"  first differing line: {case['first_differing_line']}")

    if result.get("type") == "score_records":
        lines.append(f"Missing ranks: {result.get('missing_count', 0)}")
        lines.append(f"Extra ranks: {result.get('extra_count', 0)}")
        lines.append(f"Score mismatches: {result.get('score_mismatch_count', 0)}")
    if result.get("format") == "immolate-score-file-diff-v1":
        lines.append(f"Shared scores: {result.get('shared_scores', 0)}")
        lines.append(f"Different scores: {result.get('different_scores', 0)}")
        for example in result.get("examples", []):
            lines.append(
                f"  {example['left_rank']} / {example['left_seed'] or '<empty>'}: "
                f"{example['left_score']} -> {example['right_score']}"
            )

    timing = result.get("timing", {})
    if timing:
        lines.append("Timing (right / left):")
        for case_id, values in timing.items():
            ratio = values.get("ratio")
            ratio_text = "n/a" if ratio is None else f"{ratio:.3f}x"
            lines.append(
                f"  {case_id}: {values['left_median_seconds']:.6f}s -> "
                f"{values['right_median_seconds']:.6f}s ({ratio_text})"
            )
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", type=Path)
    parser.add_argument("right", type=Path)
    parser.add_argument("--max-examples", type=int, default=100, help="detailed differences to retain; 0 retains every difference")
    parser.add_argument("--output", type=Path, help="comparison output directory")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if args.max_examples < 0:
        print("compare error: --max-examples must be nonnegative", file=sys.stderr)
        return 2
    max_examples = None if args.max_examples == 0 else args.max_examples
    try:
        result = compare_paths(args.left.resolve(), args.right.resolve(), max_examples)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"compare error: {exc}", file=sys.stderr)
        return 2

    repo_root = Path(__file__).resolve().parents[1]
    output = args.output
    if output is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        output = repo_root / "test-results" / "comparisons" / stamp
    output.mkdir(parents=True, exist_ok=True)
    report = format_report(result)
    (output / "report.txt").write_text(report, encoding="utf-8")
    write_json(output / "report.json", result)
    print(report, end="")
    print(f"Report: {output}")
    return 0 if result.get("equal") else 1


if __name__ == "__main__":
    raise SystemExit(main())
