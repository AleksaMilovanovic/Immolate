#!/usr/bin/env python3
"""Differential validator for the guarded 13-digit RNG-node recurrence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

D = 10_000_000_000_000
Q = 100_000_000
C = 172_431_234
B13 = 1_344_534_291_410
HALF = Q // 2
MARGIN = Q // 64
BASE = 10_000
MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1
OPENCL_CASE_ID = "scores-rng-advance-validate"
OPENCL_FILTER = "rng_advance_validate"
OPENCL_START_RANK = 0
OPENCL_COUNT = 4096
OPENCL_STEPS = 512
OPENCL_BLOCK_SIZE = 512


@dataclass
class Stats:
    checked: int = 0
    raw_mismatches: int = 0
    guarded_mismatches: int = 0
    fallbacks: int = 0


def native_next_k(k: int) -> int:
    state = k / D
    stepped = state * 1.72431234
    stepped = stepped + 2.134453429141
    scaled = (stepped - math.floor(stepped)) * D
    return math.floor(scaled + 0.5)


def direct_candidate(k: int) -> tuple[int, int, int]:
    quotient, remainder = divmod(k * C, Q)
    quotient = (quotient + B13) % D
    return quotient + (remainder >= HALF), quotient, remainder


def limb_candidate(k: int) -> tuple[int, int, int]:
    d0 = k % BASE
    k //= BASE
    d1 = k % BASE
    k //= BASE
    d2 = k % BASE
    d3 = k // BASE

    a0 = d0 * 1234
    a1 = d0 * 7243 + d1 * 1234
    a2 = d0 + d1 * 7243 + d2 * 1234
    a3 = d1 + d2 * 7243 + d3 * 1234
    a4 = d2 + d3 * 7243
    a5 = d3

    carry, p0 = divmod(a0, BASE)
    carry, p1 = divmod(a1 + carry, BASE)
    carry, p2 = divmod(a2 + carry, BASE)
    carry, p3 = divmod(a3 + carry, BASE)
    carry, p4 = divmod(a4 + carry, BASE)
    p5 = a5 + carry
    remainder = p0 + p1 * BASE

    carry, q0 = divmod(p2 + 1410, BASE)
    carry, q1 = divmod(p3 + 3429 + carry, BASE)
    carry, q2 = divmod(p4 + 3445 + carry, BASE)
    q3 = p5 + 1 + carry
    if q3 >= 10:
        q3 -= 10

    quotient = q0 + q1 * BASE + q2 * BASE**2 + q3 * BASE**3
    if remainder >= HALF:
        q0 += 1
        if q0 == BASE:
            q0 = 0
            q1 += 1
            if q1 == BASE:
                q1 = 0
                q2 += 1
                if q2 == BASE:
                    q2 = 0
                    q3 += 1
    rounded = q0 + q1 * BASE + q2 * BASE**2 + q3 * BASE**3
    return rounded, quotient, remainder


def guard_safe(quotient: int, remainder: int) -> bool:
    if abs(remainder - HALF) <= MARGIN:
        return False
    if quotient == 0 and remainder <= MARGIN:
        return False
    if quotient == D - 1 and remainder >= Q - MARGIN:
        return False
    return True


def validate_one(k: int, label: str, index: int, stats: Stats) -> tuple[int, bool, bool]:
    if not 0 <= k <= D:
        raise AssertionError(f"{label}[{index}] has out-of-range state {k}")
    direct, quotient, remainder = direct_candidate(k)
    limb, limb_quotient, limb_remainder = limb_candidate(k)
    if (limb, limb_quotient, limb_remainder) != (direct, quotient, remainder):
        raise AssertionError(
            f"limb mismatch at {label}[{index}], k={k}: "
            f"direct={(direct, quotient, remainder)}, limb={(limb, limb_quotient, limb_remainder)}"
        )
    native = native_next_k(k)
    safe = guard_safe(quotient, remainder)
    stats.checked += 1
    if not safe:
        stats.fallbacks += 1
    if direct != native:
        stats.raw_mismatches += 1
        if safe:
            stats.guarded_mismatches += 1
            raise AssertionError(
                f"unsafe guard at {label}[{index}], k={k}: native={native}, "
                f"candidate={direct}, quotient={quotient}, remainder={remainder}"
            )
    return native, direct != native, not safe


def xorshift64star(value: int) -> tuple[int, int]:
    value ^= value >> 12
    value ^= (value << 25) & MASK64
    value ^= value >> 27
    value &= MASK64
    return value, (value * 2_685_821_657_736_338_717) & MASK64


def boundary_states() -> list[int]:
    states = {0, 1, 2, D - 2, D - 1, D}
    for power in (1, 10, 100, 1_000, 10_000, 100_000_000, 1_000_000_000_000, D):
        for delta in range(-2, 3):
            value = power + delta
            if 0 <= value <= D:
                states.add(value)

    # The exact remainder is (k*C) mod Q. Since gcd(C,Q)=2, reduce the
    # congruence and construct states on both sides of the half/guard edges.
    gcd = math.gcd(C, Q)
    modulus = Q // gcd
    inverse = pow(C // gcd, -1, modulus)
    offsets = (
        -MARGIN - 2, -MARGIN, -MARGIN + 2,
        -4, -2, 0, 2, 4,
        MARGIN - 2, MARGIN, MARGIN + 2,
    )
    bands = (0, 1, 2, 17, 999, 49_999, 99_999, 149_999, 199_999)
    for offset in offsets:
        target = HALF + offset
        target -= target % gcd
        residue = ((target // gcd) * inverse) % modulus
        for band in bands:
            value = residue + band * modulus
            if 0 <= value <= D:
                for delta in range(-2, 3):
                    if 0 <= value + delta <= D:
                        states.add(value + delta)

    # The decimal recurrence crosses D once. Search around that exact quotient
    # boundary to cover both sides of the fract() wrap guard.
    crossing = ((D - B13) * Q) // C
    for delta in range(-4096, 4097):
        value = crossing + delta
        if 0 <= value <= D:
            states.add(value)
    return sorted(states)


def mix32(value: int) -> int:
    value &= MASK32
    value ^= value >> 16
    value = (value * 0x7FEB352D) & MASK32
    value ^= value >> 15
    value = (value * 0x846CA68B) & MASK32
    return (value ^ (value >> 16)) & MASK32


def validation_state(counter: int) -> int:
    if counter == 0:
        return 0
    if counter == 1:
        return D
    if counter == 2:
        return D - 1
    if counter == 3:
        return 1

    lo = counter & MASK32
    hi = (counter >> 32) & MASK32
    value = (lo ^ ((hi * 0x9E3779B9) & MASK32) ^ 0xA511E9B3) & MASK32
    d0 = mix32(value + 0x9E3779B9) % BASE
    d1 = mix32(value + 0x3C6EF372) % BASE
    d2 = mix32(value + 0xDAA66D2B) % BASE
    d3 = mix32(value + 0x78DDE6E4) % 10
    return d0 + d1 * BASE + d2 * BASE**2 + d3 * BASE**3


def opencl_corpus(count: int, steps: int) -> tuple[list[int], Stats]:
    stats = Stats()
    scores: list[int] = []
    for rank in range(OPENCL_START_RANK, OPENCL_START_RANK + count):
        state = validation_state(rank)
        raw_mismatches = 0
        fallbacks = 0
        for step in range(steps):
            state, raw_mismatch, fallback = validate_one(
                state, f"opencl-rank-{rank}", step, stats
            )
            raw_mismatches += raw_mismatch
            fallbacks += fallback
        scores.append(raw_mismatches * 1000 + fallbacks)
    return scores, stats


def score_hashes(scores: list[int], block_size: int) -> dict:
    whole = hashlib.sha256()
    blocks = []
    for offset in range(0, len(scores), block_size):
        digest = hashlib.sha256()
        block = scores[offset : offset + block_size]
        for score in block:
            raw = struct.pack("<q", score)
            whole.update(raw)
            digest.update(raw)
        blocks.append({
            "start_rank": OPENCL_START_RANK + offset,
            "count": len(block),
            "sha256": digest.hexdigest(),
        })
    return {
        "format": "immolate-score-hashes-v1",
        "algorithm": "sha256",
        "filter": OPENCL_FILTER,
        "start_rank": OPENCL_START_RANK,
        "count": len(scores),
        "block_size": block_size,
        "whole_sha256": whole.hexdigest(),
        "blocks": blocks,
    }


def opencl_case() -> dict:
    return {
        "id": OPENCL_CASE_ID,
        "kind": "scores",
        "tags": ["smoke", "compact", "rng_advance"],
        "filter": OPENCL_FILTER,
        "start_rank": OPENCL_START_RANK,
        "count": OPENCL_COUNT,
        "block_size": OPENCL_BLOCK_SIZE,
        "golden": f"compact/{OPENCL_CASE_ID}.json",
    }


def write_opencl_golden(path: Path, scores: list[int]) -> None:
    case = opencl_case()
    document = score_hashes(scores, OPENCL_BLOCK_SIZE)
    document["type"] = "score_hashes"
    document["case_id"] = OPENCL_CASE_ID
    document["case_sha256"] = hashlib.sha256(
        json.dumps(case, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run(
    samples: int,
    trajectory_steps: int,
    opencl_count: int,
    opencl_steps: int,
) -> tuple[Stats, list[int], Stats]:
    error_bound = Fraction(D, 1 << 50) + Fraction(1, 1 << 10)
    if error_bound >= Fraction(1, 64):
        raise AssertionError(f"analytical error bound {float(error_bound)} is not below 1/64")

    stats = Stats()
    for index, state in enumerate(boundary_states()):
        validate_one(state, "boundary", index, stats)

    starts = (0, 1, D // 3, D // 2, D - 1, D)
    for start_index, state in enumerate(starts):
        for step in range(trajectory_steps):
            state, _raw_mismatch, _fallback = validate_one(
                state, f"trajectory-{start_index}", step, stats
            )

    value = 0x9E3779B97F4A7C15
    for index in range(samples):
        value, mixed = xorshift64star(value)
        validate_one(mixed % (D + 1), "sample", index, stats)

    scores, opencl_stats = opencl_corpus(opencl_count, opencl_steps)
    hashes = score_hashes(scores, OPENCL_BLOCK_SIZE)

    print(f"analytical_scaled_error_bound={float(error_bound):.12f}")
    print(f"guard_margin={1/64:.12f}")
    print(f"checked={stats.checked}")
    print(f"raw_decimal_mismatches={stats.raw_mismatches}")
    print(f"guarded_mismatches={stats.guarded_mismatches}")
    print(f"fallbacks={stats.fallbacks}")
    print(f"fallback_rate={stats.fallbacks / stats.checked:.6%}")
    print(f"opencl_corpus_count={opencl_count}")
    print(f"opencl_corpus_steps={opencl_steps}")
    print(f"opencl_corpus_transitions={opencl_stats.checked}")
    print(f"opencl_raw_decimal_mismatches={opencl_stats.raw_mismatches}")
    print(f"opencl_guarded_mismatches={opencl_stats.guarded_mismatches}")
    print(f"opencl_fallbacks={opencl_stats.fallbacks}")
    rate = opencl_stats.fallbacks / opencl_stats.checked if opencl_stats.checked else 0.0
    print(f"opencl_fallback_rate={rate:.6%}")
    print(f"opencl_score_sha256={hashes['whole_sha256']}")
    return stats, scores, opencl_stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=1_000_000)
    parser.add_argument("--trajectory-steps", type=int, default=100_000)
    parser.add_argument("--opencl-count", type=int, default=OPENCL_COUNT)
    parser.add_argument("--opencl-steps", type=int, default=OPENCL_STEPS)
    parser.add_argument("--write-opencl-golden", type=Path)
    args = parser.parse_args()
    if min(args.samples, args.trajectory_steps, args.opencl_count, args.opencl_steps) < 0:
        parser.error("sample counts must be nonnegative")
    stats, scores, opencl_stats = run(
        args.samples,
        args.trajectory_steps,
        args.opencl_count,
        args.opencl_steps,
    )
    if args.write_opencl_golden:
        if args.opencl_count != OPENCL_COUNT or args.opencl_steps != OPENCL_STEPS:
            parser.error(
                "--write-opencl-golden requires the default OpenCL count and step count"
            )
        write_opencl_golden(args.write_opencl_golden, scores)
        print(f"wrote_opencl_golden={args.write_opencl_golden}")
    return 1 if stats.guarded_mismatches or opencl_stats.guarded_mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
