"""Reading Immolate output files whatever the shell wrote them as.

Redirecting a run with `>` in Windows PowerShell 5 produces UTF-16LE, and in
PowerShell 7 it produces UTF-8 with a BOM. Python's open() handles neither
usefully: the BOM becomes a stray character on line 1, and UTF-16 decodes as
UTF-8 into NUL-interleaved text where nothing matches, so every line is silently
skipped. Seeds and scores are ASCII, so detect the encoding and flatten it.

The C side does the same thing in lib/supplier.h (sup_normalise_text); keep the
two in step.
"""
import sys


def _decode(raw: bytes) -> str:
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", "replace")
    if raw.startswith(b"\xff\xfe"):
        return raw[2:].decode("utf-16-le", "replace")
    if raw.startswith(b"\xfe\xff"):
        return raw[2:].decode("utf-16-be", "replace")
    # No BOM: infer UTF-16 from where the NUL bytes fall. A strong majority
    # rather than all of them, so one non-ASCII character in a banner line (a
    # path, a version string) cannot disguise the encoding.
    look = raw[:512]
    look = look[: len(look) & ~1]
    pairs = len(look) // 2
    if pairs >= 2:
        odd = sum(1 for i in range(1, len(look), 2) if look[i] == 0)
        even = sum(1 for i in range(0, len(look), 2) if look[i] == 0)
        if odd >= pairs * 0.9 and even <= pairs * 0.1:
            return raw.decode("utf-16-le", "replace")
        if even >= pairs * 0.9 and odd <= pairs * 0.1:
            return raw.decode("utf-16-be", "replace")
    return raw.decode("utf-8", "replace")


def read_lines(path=None):
    """Yield the lines of `path`, or of stdin when path is None."""
    raw = open(path, "rb").read() if path else sys.stdin.buffer.read()
    return _decode(raw).splitlines()


def describe(path=None):
    """A short report of what a file actually contains, for when parsing fails."""
    raw = open(path, "rb").read() if path else b""
    if not raw:
        return "  (file is empty or unreadable)"
    head = raw[:48]
    hexs = " ".join(f"{b:02x}" for b in head)
    prin = "".join(chr(b) if 32 <= b < 127 else "." for b in head)
    lines = _decode(raw)[:400].splitlines()[:4]
    out = [f"  size: {len(raw)} bytes",
           f"  first bytes: {hexs}",
           f"               {prin}",
           f"  decoded as:  {_ENCODING_NAME[0]}"]
    for i, ln in enumerate(lines):
        out.append(f"  line {i + 1}: {ln!r}")
    return "\n".join(out)


_ENCODING_NAME = ["utf-8"]
_orig_decode = _decode


def _decode(raw: bytes) -> str:  # noqa: F811  - wraps the detector to record it
    if raw.startswith(b"\xef\xbb\xbf"):
        _ENCODING_NAME[0] = "utf-8 (BOM)"
    elif raw.startswith(b"\xff\xfe"):
        _ENCODING_NAME[0] = "utf-16-le (BOM)"
    elif raw.startswith(b"\xfe\xff"):
        _ENCODING_NAME[0] = "utf-16-be (BOM)"
    else:
        look = raw[:512]
        look = look[: len(look) & ~1]
        pairs = len(look) // 2
        odd = sum(1 for i in range(1, len(look), 2) if look[i] == 0) if pairs else 0
        even = sum(1 for i in range(0, len(look), 2) if look[i] == 0) if pairs else 0
        if pairs >= 2 and odd >= pairs * 0.9 and even <= pairs * 0.1:
            _ENCODING_NAME[0] = "utf-16-le (no BOM)"
        elif pairs >= 2 and even >= pairs * 0.9 and odd <= pairs * 0.1:
            _ENCODING_NAME[0] = "utf-16-be (no BOM)"
        else:
            _ENCODING_NAME[0] = "utf-8"
    return _orig_decode(raw)
