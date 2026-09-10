#!/usr/bin/env python3
"""Self-tests for Immolate's Python test tooling."""

from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from common import (
    FormatError,
    MAX_RANK,
    SCORE_FLAG_CLOSED,
    SCORE_HEADER,
    SCORE_MAGIC,
    SCORE_VERSION,
    SUP_FLAG_CLOSED,
    SUP_HEADER,
    SUP_MAGIC,
    SUP_VERSION,
    SUP_ENCODING,
    compare_score_files,
    hash_score_blocks,
    iter_score_values,
    normalize_snapshot,
    parse_score_records,
    rank_to_seed,
    read_supplier,
    seed_to_rank,
    validate_score_file,
    write_score_fixture,
    write_supplier_fixture,
)
from compare import compare_canonical, compare_record_documents, compare_snapshots


class SeedTests(unittest.TestCase):
    def test_round_trip_boundaries(self) -> None:
        ranks = [
            0,
            1,
            35,
            36,
            1260,
            1261,
            44135,
            44136,
            1544760,
            1544761,
            54066635,
            54066636,
            1892332260,
            1892332261,
            66231629135,
            66231629136,
            MAX_RANK,
        ]
        for rank in ranks:
            with self.subTest(rank=rank):
                self.assertEqual(seed_to_rank(rank_to_seed(rank)), rank)

    def test_invalid_seed_and_rank(self) -> None:
        with self.assertRaises(ValueError):
            seed_to_rank("0")
        with self.assertRaises(ValueError):
            seed_to_rank("111111111")
        with self.assertRaises(ValueError):
            rank_to_seed(-1)
        with self.assertRaises(ValueError):
            rank_to_seed(MAX_RANK + 1)


class TextTests(unittest.TestCase):
    def test_score_records_are_sorted(self) -> None:
        records = parse_score_records("Z (9)\nImmolate Beta vX\n (3)\n1 (-2)\n")
        self.assertEqual(records, [(0, "", 3), (1, "1", -2), (35, "Z", 9)])

    def test_duplicate_score_record_is_rejected(self) -> None:
        with self.assertRaises(FormatError):
            parse_score_records("1 (2)\n1 (3)\n")

    def test_snapshot_normalization_only_removes_host_lines(self) -> None:
        raw = (
            "Immolate Beta v1\r\n"
            "Loaded compiled kernel from cache (x)\r\n"
            "Starting searcher...\r\n"
            "-- probe\r\n"
            "value 0123\r\n"
            "Done in 1.25s"
        )
        self.assertEqual(normalize_snapshot(raw), "-- probe\nvalue 0123\n")

    def test_snapshot_diff(self) -> None:
        result = compare_snapshots("a\nb\n", "a\nc\n")
        self.assertFalse(result["equal"])
        self.assertEqual(result["first_differing_line"], 2)


class SupplierTests(unittest.TestCase):
    def test_supplier_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.immseeds"
            expected = [0, 1, 35, 36, 1_000_000, MAX_RANK]
            write_supplier_fixture(path, expected, filter_name="unit", cutoff=7)
            header, ranks = read_supplier(path)
            self.assertEqual(header.filter, "unit")
            self.assertEqual(header.cutoff, 7)
            self.assertEqual(ranks, expected)

    def test_supplier_rejects_trailing_and_truncated_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "original.immseeds"
            write_supplier_fixture(original, [1, 100])
            data = original.read_bytes()

            trailing = Path(directory) / "trailing.immseeds"
            trailing.write_bytes(data + b"x")
            with self.assertRaises(FormatError):
                read_supplier(trailing)

            truncated = Path(directory) / "truncated.immseeds"
            truncated.write_bytes(data[:-1])
            with self.assertRaises(FormatError):
                read_supplier(truncated)

    def test_supplier_rejects_zero_and_nonminimal_delta(self) -> None:
        raw_filter = b"unit".ljust(64, b"\0")
        header = SUP_HEADER.pack(
            SUP_MAGIC,
            SUP_VERSION,
            SUP_ENCODING,
            raw_filter,
            0,
            0,
            1,
            SUP_FLAG_CLOSED,
            1,
        )
        with tempfile.TemporaryDirectory() as directory:
            zero = Path(directory) / "zero.immseeds"
            zero.write_bytes(header + b"\0")
            with self.assertRaises(FormatError):
                read_supplier(zero)

            nonminimal = Path(directory) / "nonminimal.immseeds"
            nonminimal.write_bytes(header + b"\x81\x00")
            with self.assertRaises(FormatError):
                read_supplier(nonminimal)

    def test_supplier_rejects_bad_padding_and_rank_outside_header_range(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            valid = directory_path / "valid.immseeds"
            write_supplier_fixture(valid, [0], filter_name="unit", start_rank=0, num_seeds=1)

            bad_padding = bytearray(valid.read_bytes())
            bad_padding[16 + len("unit") + 1] = ord("X")
            padded = directory_path / "bad-padding.immseeds"
            padded.write_bytes(bad_padding)
            with self.assertRaises(FormatError):
                read_supplier(padded)

            raw_filter = b"unit".ljust(64, b"\0")
            outside_header = SUP_HEADER.pack(
                SUP_MAGIC,
                SUP_VERSION,
                SUP_ENCODING,
                raw_filter,
                0,
                0,
                1,
                SUP_FLAG_CLOSED,
                1,
            )
            outside = directory_path / "outside.immseeds"
            outside.write_bytes(outside_header + b"\x03")  # first delta 3 -> rank 2
            with self.assertRaises(FormatError):
                read_supplier(outside)


class ScoreFileTests(unittest.TestCase):
    def test_score_round_trip_and_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scores.scores"
            scores = [0, -1, 2**40, -(2**40), 7]
            write_score_fixture(path, scores, filter_name="unit", start_rank=35)
            header, values = iter_score_values(path)
            self.assertEqual(header.filter, "unit")
            self.assertEqual(header.start_rank, 35)
            self.assertEqual(list(values), scores)
            hashes = hash_score_blocks(path, block_size=2)
            self.assertEqual([block["count"] for block in hashes["blocks"]], [2, 2, 1])
            self.assertEqual(hashes["count"], len(scores))

    def test_score_rejects_incomplete_truncated_and_trailing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            raw_filter = b"unit".ljust(64, b"\0")

            incomplete = directory_path / "incomplete.scores"
            incomplete.write_bytes(SCORE_HEADER.pack(SCORE_MAGIC, SCORE_VERSION, 0, raw_filter, 0, 0))
            with self.assertRaises(FormatError):
                validate_score_file(incomplete)

            complete = directory_path / "complete.scores"
            write_score_fixture(complete, [1, 2])
            data = complete.read_bytes()

            truncated = directory_path / "truncated.scores"
            truncated.write_bytes(data[:-1])
            with self.assertRaises(FormatError):
                validate_score_file(truncated)

            trailing = directory_path / "trailing.scores"
            trailing.write_bytes(data + b"x")
            with self.assertRaises(FormatError):
                validate_score_file(trailing)

    def test_score_rejects_nonzero_filter_padding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            valid = Path(directory) / "valid.scores"
            write_score_fixture(valid, [1], filter_name="unit")
            data = bytearray(valid.read_bytes())
            data[16 + len("unit") + 1] = ord("X")
            malformed = Path(directory) / "bad-padding.scores"
            malformed.write_bytes(data)
            with self.assertRaises(FormatError):
                validate_score_file(malformed)

    def test_exact_score_diff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.scores"
            right = Path(directory) / "right.scores"
            write_score_fixture(left, [1, 2, 3], start_rank=10)
            write_score_fixture(right, [1, 20, 3], start_rank=10)
            result = compare_score_files(left, right)
            self.assertFalse(result["equal"])
            self.assertEqual(result["different_scores"], 1)
            self.assertEqual(result["examples"][0]["left_rank"], 11)
            self.assertEqual(result["examples"][0]["left_score"], 2)
            self.assertEqual(result["examples"][0]["right_score"], 20)


class ComparisonTests(unittest.TestCase):
    def test_record_difference_categories(self) -> None:
        left = {
            "type": "score_records",
            "records": [
                {"rank": 1, "seed": "1", "score": 10},
                {"rank": 2, "seed": "2", "score": 20},
            ],
        }
        right = {
            "type": "score_records",
            "records": [
                {"rank": 2, "seed": "2", "score": 21},
                {"rank": 3, "seed": "3", "score": 30},
            ],
        }
        result = compare_record_documents(left, right, 10)
        self.assertEqual(result["missing_count"], 1)
        self.assertEqual(result["extra_count"], 1)
        self.assertEqual(result["score_mismatch_count"], 1)

    def test_hash_document_comparison(self) -> None:
        left = {
            "type": "score_hashes",
            "algorithm": "sha256",
            "filter": "x",
            "start_rank": 0,
            "count": 1,
            "block_size": 1,
            "whole_sha256": "a",
            "blocks": [{"start_rank": 0, "count": 1, "sha256": "a"}],
        }
        right = dict(left)
        right["whole_sha256"] = "b"
        right["blocks"] = [{"start_rank": 0, "count": 1, "sha256": "b"}]
        result = compare_canonical(left, right, 10)
        self.assertFalse(result["equal"])
        self.assertEqual(result["changed_block_count"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
