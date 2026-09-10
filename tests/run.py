#!/usr/bin/env python3
"""Run Immolate's deterministic correctness and performance suite."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

from common import (
    FormatError,
    MAX_RANK,
    TOTAL_SEEDS,
    hash_score_blocks,
    has_cache_overflow,
    host_metadata,
    iter_score_values,
    load_json,
    normalize_snapshot,
    parse_score_records,
    rank_to_seed,
    read_supplier,
    run_command,
    score_records_json,
    sha256_file,
    timing_summary,
    write_json,
)
from compare import compare_canonical, compare_record_documents


class CaseFailure(RuntimeError):
    pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("smoke", "quick", "correctness", "breadth", "benchmark", "rng-advance", "all"), default="all")
    parser.add_argument("--scale", choices=("auto", "pocl", "rtx5080"), default="auto")
    parser.add_argument("--platform", type=int, default=0)
    parser.add_argument("--device", type=int, default=0)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--repeat", type=int, help="override measured benchmark repetitions")
    parser.add_argument("--timeout", type=float, default=600.0, help="per-command timeout in seconds")
    parser.add_argument("--batch", type=int, help="override score/prefilter batch size")
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--build-dir", type=Path, default=Path("build"))
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--update-golden", action="store_true")
    parser.add_argument("--discard-scores", action="store_true")
    parser.add_argument("--cases", type=Path, default=Path(__file__).with_name("cases.json"))
    return parser.parse_args(argv)


def resolve_value(value: Any, scale: str) -> Any:
    return value[scale] if isinstance(value, dict) else value


def save_result(case_dir: Path, name: str, result: Any) -> None:
    (case_dir / f"{name}.stdout.txt").write_text(result.stdout, encoding="utf-8")
    (case_dir / f"{name}.stderr.txt").write_text(result.stderr, encoding="utf-8")
    write_json(case_dir / f"{name}.command.json", result.as_dict())


def require_success(result: Any, label: str) -> None:
    if result.timed_out:
        raise CaseFailure(f"{label} timed out")
    if result.returncode != 0:
        raise CaseFailure(f"{label} exited with status {result.returncode}")
    if has_cache_overflow(result.stdout, result.stderr):
        raise CaseFailure(f"{label} reported a cache overflow")


def run_checked(
    argv: Sequence[str | os.PathLike[str]],
    *,
    repo_root: Path,
    timeout: float,
    case_dir: Path,
    name: str,
) -> Any:
    result = run_command(argv, cwd=repo_root, timeout=timeout)
    save_result(case_dir, name, result)
    require_success(result, name)
    return result


def base_command(exe: Path, platform_id: int, device_id: int, filter_name: str) -> list[str]:
    return [str(exe), "-p", str(platform_id), "-d", str(device_id), "-f", filter_name]


def range_args(start_rank: int, count: int) -> list[str]:
    if start_rank < 0 or count < 0 or start_rank > TOTAL_SEEDS or count > TOTAL_SEEDS - start_rank:
        raise CaseFailure(f"invalid rank range {start_rank}+{count}; maximum rank is {MAX_RANK}")
    return ["-s", rank_to_seed(start_rank), "-n", str(count)]


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


def run_snapshot(case: dict, ctx: dict, case_dir: Path) -> tuple[dict, dict]:
    command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
    command += ["-s", case["seed"], "-n", "1", "-g", "1"]
    result = run_checked(command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name="run")
    canonical = {"type": "snapshot", "text": normalize_snapshot(result.stdout)}
    return canonical, {"timing": timing_summary([result.wall_ns])}


def run_scores(case: dict, ctx: dict, case_dir: Path) -> tuple[dict, dict]:
    start_rank = int(case["start_rank"])
    count = int(resolve_value(case["count"], ctx["scale"]))
    score_path = case_dir / f"{case['id']}.scores"
    command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
    command += range_args(start_rank, count)
    command += ["--scores_to", str(score_path), "--batch", str(ctx["batch"])]
    result = run_checked(command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name="run")
    if not score_path.exists():
        raise CaseFailure("score command succeeded without creating its score file")
    canonical = hash_score_blocks(score_path, int(case.get("block_size", 65_536)))
    canonical["type"] = "score_hashes"
    canonical["case_id"] = case["id"]
    canonical["case_sha256"] = hashlib.sha256(
        json.dumps(case, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    metrics = {
        "timing": timing_summary([result.wall_ns]),
        "score_file": score_path.name,
        "score_file_bytes": score_path.stat().st_size,
    }
    if ctx["discard_scores"]:
        score_path.unlink()
        metrics["score_file_discarded"] = True
    return canonical, metrics


def run_records_equivalence(case: dict, ctx: dict, case_dir: Path) -> tuple[dict, dict]:
    start_rank = int(case["start_rank"])
    count = int(resolve_value(case["count"], ctx["scale"]))
    documents = []
    wall = []
    for index, extra in enumerate(case["variants"]):
        command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
        command += range_args(start_rank, count)
        command += ["-c", str(case["cutoff"]), "--batch", str(ctx["batch"])]
        command += list(extra)
        result = run_checked(command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name=f"variant-{index + 1}")
        wall.append(result.wall_ns)
        document = score_records_json(parse_score_records(result.stdout))
        document["type"] = "score_records"
        write_json(case_dir / f"variant-{index + 1}.canonical.json", document)
        documents.append(document)
    comparison = compare_record_documents(documents[0], documents[1], 100)
    canonical = {"type": "equivalence", "equal": comparison["equal"], "comparison": comparison}
    if not comparison["equal"]:
        raise CaseFailure("record variants produced different survivor scores")
    return canonical, {"timing": timing_summary(wall)}


def run_cutoff_equivalence(case: dict, ctx: dict, case_dir: Path) -> tuple[dict, dict]:
    start_rank = int(case["start_rank"])
    count = int(resolve_value(case["count"], ctx["scale"]))
    cutoff = int(case["cutoff"])
    score_path = case_dir / "exact.scores"

    exact_command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
    exact_command += range_args(start_rank, count)
    exact_command += ["--scores_to", str(score_path), "--batch", str(ctx["batch"])]
    exact = run_checked(exact_command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name="exact")

    cutoff_command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
    cutoff_command += range_args(start_rank, count)
    cutoff_command += ["-c", str(cutoff), "--batch", str(ctx["batch"])]
    filtered = run_checked(cutoff_command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name="cutoff")

    header, values = iter_score_values(score_path)
    expected = set()
    for index, score in enumerate(values):
        if score >= cutoff:
            expected.add(header.start_rank + index)
    actual_records = parse_score_records(filtered.stdout)
    actual = {rank for rank, _seed, _score in actual_records}
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    canonical = {
        "type": "cutoff_equivalence",
        "equal": not missing and not extra,
        "cutoff": cutoff,
        "expected_count": len(expected),
        "actual_count": len(actual),
        "missing": missing[:100],
        "extra": extra[:100],
        "missing_count": len(missing),
        "extra_count": len(extra),
    }
    if ctx["discard_scores"]:
        score_path.unlink()
    if missing or extra:
        raise CaseFailure(f"cutoff survivor set differs: {len(missing)} missing, {len(extra)} extra")
    return canonical, {"timing": timing_summary([exact.wall_ns, filtered.wall_ns])}


def run_supplier_pipeline(case: dict, ctx: dict, case_dir: Path) -> tuple[dict, dict]:
    start_rank = int(case["start_rank"])
    count = int(resolve_value(case["count"], ctx["scale"]))
    final_cutoff = int(case["final_cutoff"])
    pool_cutoff = int(case["pool_cutoff"])
    parts = int(case["parts"])
    direct_path = case_dir / "direct.immseeds"
    pool_path = case_dir / "pool.immseeds"
    staged_path = case_dir / "staged.immseeds"
    parts_base = case_dir / "parts.immseeds"
    wall = []

    def collect(name: str, cutoff: int, output: Path, extra: Sequence[str] = ()) -> Any:
        command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
        command += range_args(start_rank, count)
        command += ["-c", str(cutoff), "--to", str(output), "--batch", str(ctx["batch"])]
        command += list(extra)
        result = run_checked(command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name=name)
        wall.append(result.wall_ns)
        return result

    collect("direct", final_cutoff, direct_path)
    collect("pool", pool_cutoff, pool_path)

    staged_command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
    staged_command += ["-c", str(final_cutoff), "--from", str(pool_path), "--to", str(staged_path), "--batch", str(ctx["batch"])]
    staged = run_checked(staged_command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name="staged")
    wall.append(staged.wall_ns)

    collect("parts", final_cutoff, parts_base, ["--to_parts", str(parts)])

    direct_header, direct_ranks = read_supplier(direct_path)
    _staged_header, staged_ranks = read_supplier(staged_path)
    part_ranks: list[int] = []
    for part in range(1, parts + 1):
        path = Path(f"{parts_base}.part{part}of{parts}")
        _header, ranks = read_supplier(path)
        part_ranks.extend(ranks)
    staged_equal = direct_ranks == staged_ranks
    parts_equal = direct_ranks == part_ranks
    canonical = {
        "type": "supplier_pipeline",
        "equal": staged_equal and parts_equal,
        "direct_count": len(direct_ranks),
        "pool_count": read_supplier(pool_path)[0].count,
        "staged_equal": staged_equal,
        "parts_equal": parts_equal,
        "header": {
            "filter": direct_header.filter,
            "cutoff": direct_header.cutoff,
            "start_rank": direct_header.start_rank,
            "num_seeds": direct_header.num_seeds,
        },
    }
    if not canonical["equal"]:
        raise CaseFailure("direct, staged, and multipart supplier outputs differ")
    return canonical, {"timing": timing_summary(wall)}


def run_benchmark(case: dict, ctx: dict, case_dir: Path) -> tuple[dict, dict]:
    count = int(resolve_value(case["count"], ctx["scale"]))
    command = base_command(ctx["exe"], ctx["platform"], ctx["device"], case["filter"])
    command += ["-s", case["seed"], "-n", str(count), "-c", str(case["cutoff"]), "--batch", str(ctx["batch"])]
    warm = run_checked(command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name="warmup")
    if parse_score_records(warm.stdout):
        raise CaseFailure("benchmark warmup unexpectedly printed result records")
    samples = []
    for repeat in range(ctx["repeats"]):
        result = run_checked(command, repo_root=ctx["repo"], timeout=ctx["timeout"], case_dir=case_dir, name=f"sample-{repeat + 1}")
        if parse_score_records(result.stdout):
            raise CaseFailure("benchmark unexpectedly printed result records")
        samples.append(result.wall_ns)
    canonical = {"type": "benchmark", "filter": case["filter"], "count": count, "cutoff": int(case["cutoff"])}
    return canonical, {"timing": timing_summary(samples), "warmup_seconds": warm.wall_ns / 1_000_000_000}


CASE_RUNNERS = {
    "snapshot": run_snapshot,
    "scores": run_scores,
    "records_equivalence": run_records_equivalence,
    "cutoff_equivalence": run_cutoff_equivalence,
    "supplier_pipeline": run_supplier_pipeline,
    "benchmark": run_benchmark,
}


def detect_device_name(listing: str, platform_id: int, device_id: int) -> str | None:
    current = None
    for line in listing.splitlines():
        match = re.fullmatch(r"Platform ID ([0-9]+), Device ID ([0-9]+)", line.strip())
        if match:
            current = (int(match.group(1)), int(match.group(2)))
            continue
        if current == (platform_id, device_id) and line.startswith("Name: "):
            return line[6:].strip()
    return None


def choose_scale(requested: str, device_name: str | None) -> str:
    if requested != "auto":
        return requested
    name = (device_name or "").lower()
    if "rtx 5080" in name or "geforce rtx 5080" in name:
        return "rtx5080"
    return "pocl"


def find_executable(repo: Path, build_dir: Path, explicit: Path | None) -> Path:
    if explicit:
        path = explicit if explicit.is_absolute() else repo / explicit
        if not path.exists():
            raise CaseFailure(f"executable does not exist: {path}")
        return path.resolve()
    candidates = (
        build_dir / "Immolate",
        build_dir / "Immolate.exe",
        build_dir / "Release" / "Immolate",
        build_dir / "Release" / "Immolate.exe",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    raise CaseFailure(f"could not find Immolate under {build_dir}")


def git_capture(repo: Path, *args: str) -> str:
    result = run_command(["git", *args], cwd=repo, timeout=30)
    if result.returncode != 0:
        raise CaseFailure(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def prepare_results_dir(repo: Path, requested: Path | None, sha: str) -> Path:
    if requested:
        result = requested if requested.is_absolute() else repo / requested
    else:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        result = repo / "test-results" / f"{stamp}-{sha[:8]}"
    result = result.resolve()
    if result.exists() and any(result.iterdir()):
        raise CaseFailure(f"results directory is not empty: {result}")
    result.mkdir(parents=True, exist_ok=True)
    return result


def build_project(repo: Path, build_dir: Path, timeout: float, results: Path) -> None:
    configure = run_command(
        ["cmake", "-S", str(repo), "-B", str(build_dir), "-DCMAKE_BUILD_TYPE=Release"],
        cwd=repo,
        timeout=timeout,
    )
    save_result(results, "build-configure", configure)
    require_success(configure, "cmake configure")
    build = run_command(["cmake", "--build", str(build_dir), "--config", "Release"], cwd=repo, timeout=timeout)
    save_result(results, "build", build)
    require_success(build, "cmake build")


def update_or_check_golden(case: dict, canonical: dict, ctx: dict) -> tuple[bool, str]:
    relative = case.get("golden")
    if not relative:
        return True, "internal equivalence"
    golden_path = ctx["golden_root"] / relative
    if ctx["update_golden"]:
        write_json(golden_path, canonical)
        return True, f"updated {golden_path.relative_to(ctx['repo'])}"
    if not golden_path.exists():
        return False, f"missing golden {golden_path.relative_to(ctx['repo'])}; run with --update-golden"
    comparison = compare_canonical(load_json(golden_path), canonical, 100)
    if comparison.get("equal"):
        return True, "matches golden"
    write_json(ctx["current_case_dir"] / "golden-diff.json", comparison)
    return False, "does not match golden"


def summary_text(summary: dict) -> str:
    lines = [
        f"Immolate suite: {summary['profile']} ({summary['scale']})",
        f"Correctness: {'PASS' if summary['passed'] else 'FAIL'}",
        "",
    ]
    for case in summary["cases"]:
        marker = "PASS" if case["passed"] else "FAIL"
        timing = case.get("median_seconds")
        timing_text = "" if timing is None else f"  {timing:.6f}s median"
        lines.append(f"[{marker}] {case['id']}{timing_text}  {case['message']}")
    for comparison in summary.get("timing_comparisons", []):
        lines.append(
            f"[RATIO] {comparison['id']} / {comparison['baseline_id']}: "
            f"{comparison['ratio']:.3f}x"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    repo = Path(__file__).resolve().parents[1]
    cases_path = args.cases.resolve()
    config = load_json(cases_path)
    if config.get("schema") != 1:
        print("unsupported cases.json schema", file=sys.stderr)
        return 2
    if args.repeat is not None and args.repeat < 1:
        print("--repeat must be positive", file=sys.stderr)
        return 2
    if args.batch is not None and args.batch < 1:
        print("--batch must be positive", file=sys.stderr)
        return 2

    try:
        sha = git_capture(repo, "rev-parse", "HEAD")
        dirty = git_capture(repo, "status", "--porcelain")
        results = prepare_results_dir(repo, args.results, sha)
        build_dir = args.build_dir if args.build_dir.is_absolute() else repo / args.build_dir
        if not args.no_build:
            build_project(repo, build_dir, args.timeout, results)
        exe = find_executable(repo, build_dir, args.exe)

        selfcheck = run_command([sys.executable, str(repo / "tests" / "selfcheck.py")], cwd=repo, timeout=args.timeout)
        save_result(results, "selfcheck", selfcheck)
        require_success(selfcheck, "test tooling self-check")

        device_result = run_command([str(exe), "--list_devices"], cwd=repo, timeout=args.timeout)
        save_result(results, "devices", device_result)
        require_success(device_result, "device listing")
        device_name = detect_device_name(device_result.stdout, args.platform, args.device)
        if device_name is None:
            raise CaseFailure(f"selected device {args.platform}:{args.device} was not present in --list_devices output")
        scale = choose_scale(args.scale, device_name)
        scale_config = config["scales"][scale]
        batch = args.batch or int(scale_config["batch"])
        repeats = args.repeat or int(scale_config["benchmark_repeats"])
        selected_tags = set(config["profiles"][args.profile])
        selected_cases = [case for case in config["cases"] if selected_tags.intersection(case["tags"])]

        manifest = {
            "format": "immolate-suite-run-v1",
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "profile": args.profile,
            "scale": scale,
            "platform_id": args.platform,
            "device_id": args.device,
            "device_name": device_name,
            "device_listing": device_result.stdout,
            "git_sha": sha,
            "git_dirty": bool(dirty),
            "git_status": dirty,
            "executable": str(exe),
            "executable_sha256": sha256_file(exe),
            "cases_file": str(cases_path),
            "cases_sha256": sha256_file(cases_path),
            "batch": batch,
            "benchmark_repeats": repeats,
            "host": host_metadata(),
            "argv": sys.argv,
        }
        write_json(results / "manifest.json", manifest)

        ctx = {
            "repo": repo,
            "exe": exe,
            "platform": args.platform,
            "device": args.device,
            "scale": scale,
            "batch": batch,
            "repeats": repeats,
            "timeout": args.timeout,
            "discard_scores": args.discard_scores,
            "update_golden": args.update_golden,
            "golden_root": repo / "tests" / "golden",
        }
        case_summaries = []
        for index, case in enumerate(selected_cases, 1):
            case_id = case["id"]
            case_dir = results / "cases" / case_id
            case_dir.mkdir(parents=True, exist_ok=True)
            ctx["current_case_dir"] = case_dir
            print(f"[{index}/{len(selected_cases)}] {case_id}", flush=True)
            passed = False
            message = ""
            metrics: dict = {}
            try:
                runner = CASE_RUNNERS[case["kind"]]
                canonical, metrics = runner(case, ctx, case_dir)
                write_json(case_dir / "canonical.json", canonical)
                passed, message = update_or_check_golden(case, canonical, ctx)
            except Exception as exc:
                message = str(exc)
                (case_dir / "error.txt").write_text(traceback.format_exc(), encoding="utf-8")
            write_json(case_dir / "metrics.json", metrics)
            median = metrics.get("timing", {}).get("median_seconds")
            case_summaries.append({
                "id": case_id,
                "kind": case["kind"],
                "passed": passed,
                "message": message,
                "median_seconds": median,
            })

        summaries_by_id = {case["id"]: case for case in case_summaries}
        timing_comparisons = []
        for case in selected_cases:
            baseline_id = case.get("compare_to")
            if not baseline_id:
                continue
            current = summaries_by_id.get(case["id"])
            baseline = summaries_by_id.get(baseline_id)
            current_median = current.get("median_seconds") if current else None
            baseline_median = baseline.get("median_seconds") if baseline else None
            if current_median is not None and baseline_median:
                timing_comparisons.append({
                    "id": case["id"],
                    "baseline_id": baseline_id,
                    "ratio": current_median / baseline_median,
                })

        summary = {
            "format": "immolate-suite-summary-v1",
            "profile": args.profile,
            "scale": scale,
            "passed": all(case["passed"] for case in case_summaries),
            "cases": case_summaries,
            "timing_comparisons": timing_comparisons,
        }
        write_json(results / "summary.json", summary)
        text = summary_text(summary)
        (results / "summary.txt").write_text(text, encoding="utf-8")
        print("\n" + text, end="")
        print(f"Results: {results}")
        return 0 if summary["passed"] else 1
    except Exception as exc:
        print(f"suite error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
