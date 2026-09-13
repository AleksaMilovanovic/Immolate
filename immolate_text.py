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
    # No BOM: infer UTF-16 from where the NUL bytes fall.
    look = raw[:256]
    look = look[: len(look) & ~1]
    if len(look) >= 4:
        odd = sum(1 for i in range(1, len(look), 2) if look[i] == 0)
        even = sum(1 for i in range(0, len(look), 2) if look[i] == 0)
        pairs = len(look) // 2
        if odd == pairs and even == 0:
            return raw.decode("utf-16-le", "replace")
        if even == pairs and odd == 0:
            return raw.decode("utf-16-be", "replace")
    return raw.decode("utf-8", "replace")


def read_lines(path=None):
    """Yield the lines of `path`, or of stdin when path is None."""
    raw = open(path, "rb").read() if path else sys.stdin.buffer.read()
    return _decode(raw).splitlines()
