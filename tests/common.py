#!/usr/bin/env python3
"""Shared helpers for the Immolate correctness and benchmark suite."""

from __future__ import annotations

import hashlib
import json
import math
import os
import platform
import re
import statistics
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator, Sequence

SEED_CHARS = "123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
SEED_INDEX = {c: i + 1 for i, c in enumerate(SEED_CHARS)}
MAX_RANK = 2_318_107_019_760
TOTAL_SEEDS = MAX_RANK + 1

SUP_MAGIC = b"IMMSEEDS"
SUP_VERSION = 1
SUP_ENCODING = 1
SUP_HEADER = struct.Struct("<8sII64sqqqIQ")
SUP_FLAG_CLOSED = 1

SCORE_MAGIC = b"IMMSCORE"
SCORE_VERSION = 1
SCORE_HEADER = struct.Struct("<8sII64sqQ")
SCORE_FLAG_CLOSED = 1

SCORE_RECORD_RE = re.compile(r"^([1-9A-Z]*) \((-?[0-9]+)\)$")
CACHE_OVERFLOW_RE = re.compile(r"(?:cache.*overflow|overflow.*cache)", re.IGNORECASE)

_HOST_LINE_PATTERNS = (
    re.compile(r"^Immolate Beta "),
    re.compile(r"^Warning: Kernel not found at .*, attempting working directory\.\.\.$"),
    re.compile(r"^Loaded compiled kernel from cache "),
    re.compile(r"^Cached kernel binary "),
    re.compile(r"^Building program\.\.\.$"),
    re.compile(r"^Saved compiled kernel to cache\.$"),
    re.compile(r"^Launching [0-9]+ work-groups "),
    re.compile(r"^Work-group size [0-9]+ rejected "),
    re.compile(r"^Starting searcher\.\.\.$"),
    re.compile(r"^Done in [0-9.eE+-]+s$"),
    re.compile(r"^This driver rejected -cl-nv-verbose "),
)


class FormatError(ValueError):
    """Raised when a suite artifact is malformed."""


@dataclass(frozen=True)
class SupplierHeader:
    filter: str
    cutoff: int
    start_rank: int
    num_seeds: int
    flags: int
    count: int


@dataclass(frozen=True)
class ScoreHeader:
    filter: str
    start_rank: int
    count: int
    flags: int


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    wall_ns: int
    timed_out: bool

    def as_dict(self) -> dict:
        return {
            "argv": list(self.argv),
            "returncode": self.returncode,
            "wall_ns": self.wall_ns,
            "wall_seconds": self.wall_ns / 1_000_000_000,
            "timed_out": self.timed_out,
        }


def seed_to_rank(seed: str) -> int:
    if len(seed) > 8:
        raise ValueError(f"seed is longer than eight characters: {seed!r}")
    rank = 0
    for char in seed:
        try:
            digit = SEED_INDEX[char]
        except KeyError as exc:
            raise ValueError(f"invalid seed character {char!r} in {seed!r}") from exc
        rank = rank * 35 + digit
    if rank > MAX_RANK:
        raise ValueError(f"seed is outside the modeled rank domain: {seed!r}")
    return rank


def rank_to_seed(rank: int) -> str:
    if not 0 <= rank <= MAX_RANK:
        raise ValueError(f"rank must be in 0..{MAX_RANK}: {rank}")
    chars: list[str] = []
    while rank:
        rank, rem = divmod(rank - 1, 35)
        chars.append(SEED_CHARS[rem])
    return "".join(reversed(chars))


def parse_score_records(text: str) -> list[tuple[int, str, int]]:
    by_rank: dict[int, tuple[str, int]] = {}
    for raw_line in text.replace("\r\n", "\n").replace("\r", "\n").splitlines():
        match = SCORE_RECORD_RE.fullmatch(raw_line)
        if not match:
            continue
        seed, raw_score = match.groups()
        rank = seed_to_rank(seed)
        if rank in by_rank:
            raise FormatError(f"duplicate score record for rank {rank} ({seed!r})")
        by_rank[rank] = (seed, int(raw_score))
    return [(rank, seed, score) for rank, (seed, score) in sorted(by_rank.items())]


def score_records_json(records: Sequence[tuple[int, str, int]]) -> dict:
    return {
        "format": "immolate-score-records-v1",
        "records": [
            {"rank": rank, "seed": seed, "score": score}
            for rank, seed, score in records
        ],
    }


def normalize_snapshot(text: str) -> str:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    kept: list[str] = []
    for line in lines:
        if any(pattern.match(line) for pattern in _HOST_LINE_PATTERNS):
            continue
        kept.append(line.rstrip())
    while kept and kept[-1] == "":
        kept.pop()
    return "\n".join(kept) + ("\n" if kept else "")


def has_cache_overflow(stdout: str, stderr: str) -> bool:
    return bool(CACHE_OVERFLOW_RE.search(stdout) or CACHE_OVERFLOW_RE.search(stderr))


def decode_c_string(raw: bytes) -> str:
    terminator = raw.find(b"\0")
    if terminator < 0:
        raise FormatError("fixed-width string is missing its NUL terminator")
    if any(raw[terminator + 1 :]):
        raise FormatError("fixed-width string has nonzero bytes after its terminator")
    return raw[:terminator].decode("utf-8", errors="strict")


def read_supplier(path: Path) -> tuple[SupplierHeader, list[int]]:
    data = path.read_bytes()
    if len(data) < SUP_HEADER.size:
        raise FormatError("supplier file is shorter than its header")
    magic, version, encoding, raw_filter, cutoff, start_rank, num_seeds, flags, count = SUP_HEADER.unpack_from(data)
    if magic != SUP_MAGIC:
        raise FormatError("supplier file has bad magic")
    if version != SUP_VERSION:
        raise FormatError(f"unsupported supplier version {version}")
    if encoding != SUP_ENCODING:
        raise FormatError(f"unsupported supplier encoding {encoding}")
    if not flags & SUP_FLAG_CLOSED:
        raise FormatError("supplier file is not marked complete")
    if start_rank < 0 or num_seeds < 0 or start_rank > TOTAL_SEEDS or num_seeds > TOTAL_SEEDS - start_rank:
        raise FormatError("supplier header range is outside the modeled seed domain")

    pos = SUP_HEADER.size
    prev = -1
    ranks: list[int] = []
    for record_index in range(count):
        value = 0
        shift = 0
        encoded = bytearray()
        for byte_index in range(10):
            if pos >= len(data):
                raise FormatError(f"supplier body ends during record {record_index}")
            byte = data[pos]
            pos += 1
            encoded.append(byte)
            if byte_index == 9 and byte > 1:
                raise FormatError(f"supplier varint {record_index} overflows uint64")
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                break
            shift += 7
        else:
            raise FormatError(f"supplier varint {record_index} is too long")
        minimal = encode_uvarint(value)
        if bytes(encoded) != minimal:
            raise FormatError(f"supplier varint {record_index} is not minimally encoded")
        if value == 0:
            raise FormatError(f"supplier rank delta {record_index} is zero")
        rank = prev + value
        if rank > MAX_RANK:
            raise FormatError(f"supplier rank {rank} is outside the modeled seed domain")
        if not start_rank <= rank < start_rank + num_seeds:
            raise FormatError(
                f"supplier rank {rank} is outside its declared range "
                f"[{start_rank}, {start_rank + num_seeds})"
            )
        ranks.append(rank)
        prev = rank
    if pos != len(data):
        raise FormatError(f"supplier file has {len(data) - pos} trailing bytes")
    return SupplierHeader(decode_c_string(raw_filter), cutoff, start_rank, num_seeds, flags, count), ranks


def encode_uvarint(value: int) -> bytes:
    if not 0 <= value <= (1 << 64) - 1:
        raise ValueError("unsigned varint value is outside uint64")
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def write_supplier_fixture(
    path: Path,
    ranks: Sequence[int],
    *,
    filter_name: str = "fixture",
    cutoff: int = 0,
    start_rank: int = 0,
    num_seeds: int = TOTAL_SEEDS,
) -> None:
    previous = -1
    body = bytearray()
    for rank in ranks:
        if rank <= previous or rank > MAX_RANK:
            raise ValueError("supplier fixture ranks must be strictly increasing and in range")
        body.extend(encode_uvarint(rank - previous))
        previous = rank
    raw_filter = filter_name.encode("utf-8")[:63].ljust(64, b"\0")
    header = SUP_HEADER.pack(
        SUP_MAGIC,
        SUP_VERSION,
        SUP_ENCODING,
        raw_filter,
        cutoff,
        start_rank,
        num_seeds,
        SUP_FLAG_CLOSED,
        len(ranks),
    )
    path.write_bytes(header + body)


def read_score_header(stream: BinaryIO) -> ScoreHeader:
    raw = stream.read(SCORE_HEADER.size)
    if len(raw) != SCORE_HEADER.size:
        raise FormatError("score file is shorter than its header")
    magic, version, flags, raw_filter, start_rank, count = SCORE_HEADER.unpack(raw)
    if magic != SCORE_MAGIC:
        raise FormatError("score file has bad magic")
    if version != SCORE_VERSION:
        raise FormatError(f"unsupported score-file version {version}")
    if not flags & SCORE_FLAG_CLOSED:
        raise FormatError("score file is not marked complete")
    if start_rank < 0 or count > TOTAL_SEEDS or start_rank > TOTAL_SEEDS - count:
        raise FormatError("score-file range is outside the modeled seed domain")
    return ScoreHeader(decode_c_string(raw_filter), start_rank, count, flags)


def iter_score_values(path: Path) -> tuple[ScoreHeader, Iterator[int]]:
    stream = path.open("rb")
    try:
        header = read_score_header(stream)
    except Exception:
        stream.close()
        raise

    def values() -> Iterator[int]:
        try:
            for index in range(header.count):
                raw = stream.read(8)
                if len(raw) != 8:
                    raise FormatError(f"score file ends after {index} of {header.count} scores")
                yield struct.unpack("<q", raw)[0]
            trailing = stream.read(1)
            if trailing:
                raise FormatError("score file has trailing bytes")
        finally:
            stream.close()

    return header, values()


def validate_score_file(path: Path) -> ScoreHeader:
    header, values = iter_score_values(path)
    for _ in values:
        pass
    return header


def write_score_fixture(path: Path, scores: Sequence[int], *, filter_name: str = "fixture", start_rank: int = 0) -> None:
    if start_rank < 0 or start_rank > TOTAL_SEEDS - len(scores):
        raise ValueError("score fixture range is outside the modeled seed domain")
    raw_filter = filter_name.encode("utf-8")[:63].ljust(64, b"\0")
    header = SCORE_HEADER.pack(
        SCORE_MAGIC,
        SCORE_VERSION,
        SCORE_FLAG_CLOSED,
        raw_filter,
        start_rank,
        len(scores),
    )
    with path.open("wb") as stream:
        stream.write(header)
        for score in scores:
            stream.write(struct.pack("<q", score))


def hash_score_blocks(path: Path, block_size: int = 65_536) -> dict:
    if block_size < 1:
        raise ValueError("block size must be positive")
    header, values = iter_score_values(path)
    whole = hashlib.sha256()
    blocks: list[dict] = []
    block_hash = hashlib.sha256()
    block_start = header.start_rank
    block_count = 0
    seen = 0
    for score in values:
        raw = struct.pack("<q", score)
        whole.update(raw)
        block_hash.update(raw)
        block_count += 1
        seen += 1
        if block_count == block_size:
            blocks.append({
                "start_rank": block_start,
                "count": block_count,
                "sha256": block_hash.hexdigest(),
            })
            block_start += block_count
            block_count = 0
            block_hash = hashlib.sha256()
    if block_count:
        blocks.append({
            "start_rank": block_start,
            "count": block_count,
            "sha256": block_hash.hexdigest(),
        })
    if seen != header.count:
        raise FormatError(f"score file yielded {seen} values but declared {header.count}")
    return {
        "format": "immolate-score-hashes-v1",
        "algorithm": "sha256",
        "filter": header.filter,
        "start_rank": header.start_rank,
        "count": header.count,
        "block_size": block_size,
        "whole_sha256": whole.hexdigest(),
        "blocks": blocks,
    }


def compare_score_files(left: Path, right: Path, *, max_examples: int | None = 100) -> dict:
    left_header, left_values = iter_score_values(left)
    right_header, right_values = iter_score_values(right)
    header_differences = {}
    for field in ("filter", "start_rank", "count"):
        before = getattr(left_header, field)
        after = getattr(right_header, field)
        if before != after:
            header_differences[field] = {"left": before, "right": after}

    shared = min(left_header.count, right_header.count)
    differences: list[dict] = []
    difference_count = 0
    try:
        for index in range(shared):
            left_score = next(left_values)
            right_score = next(right_values)
            if left_score != right_score:
                difference_count += 1
                if max_examples is None or len(differences) < max_examples:
                    left_rank = left_header.start_rank + index
                    right_rank = right_header.start_rank + index
                    differences.append({
                        "index": index,
                        "left_rank": left_rank,
                        "left_seed": rank_to_seed(left_rank),
                        "left_score": left_score,
                        "right_rank": right_rank,
                        "right_seed": rank_to_seed(right_rank),
                        "right_score": right_score,
                    })
        for _ in left_values:
            pass
        for _ in right_values:
            pass
    finally:
        close_left = getattr(left_values, "close", None)
        close_right = getattr(right_values, "close", None)
        if close_left:
            close_left()
        if close_right:
            close_right()

    return {
        "format": "immolate-score-file-diff-v1",
        "equal": not header_differences and difference_count == 0,
        "header_differences": header_differences,
        "shared_scores": shared,
        "different_scores": difference_count,
        "examples": differences,
    }


def run_command(
    argv: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path,
    timeout: float | None,
    env: dict[str, str] | None = None,
) -> CommandResult:
    command = tuple(os.fspath(arg) for arg in argv)
    started = time.perf_counter_ns()
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
        timed_out = False
        returncode = completed.returncode
        stdout = completed.stdout
        stderr = completed.stderr
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        returncode = -1
        stdout = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or "")
    elapsed = time.perf_counter_ns() - started
    return CommandResult(command, returncode, stdout, stderr, elapsed, timed_out)


def timing_summary(samples_ns: Sequence[int]) -> dict:
    if not samples_ns:
        return {"samples_ns": []}
    ordered = sorted(samples_ns)
    median = statistics.median(ordered)
    deviations = [abs(sample - median) for sample in ordered]
    mad = statistics.median(deviations)
    mean = statistics.fmean(ordered)
    p90_index = max(0, math.ceil(0.9 * len(ordered)) - 1)
    return {
        "samples_ns": list(samples_ns),
        "samples_seconds": [sample / 1_000_000_000 for sample in samples_ns],
        "median_seconds": median / 1_000_000_000,
        "min_seconds": ordered[0] / 1_000_000_000,
        "max_seconds": ordered[-1] / 1_000_000_000,
        "p90_seconds": ordered[p90_index] / 1_000_000_000,
        "mad_seconds": mad / 1_000_000_000,
        "coefficient_of_variation": statistics.pstdev(ordered) / mean if len(ordered) > 1 and mean else 0.0,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def host_metadata() -> dict:
    return {
        "python": sys.version,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
    }
