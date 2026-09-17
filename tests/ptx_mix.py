#!/usr/bin/env python3
"""Static instruction-mix of the `search` entry in an NVIDIA OpenCL PTX binary.

Usage: ptx_mix.py <file.bin> [entry]
Counts PTX instructions by class inside the chosen .entry (default `search`),
after inlining the driver already did. Also reports the local (stack) frame
size and the number of ld/st.local, constant loads and branches. PTX is not
SASS, so these are approximate weights, but the fp64 / int64 / conversion
classes map nearly one-to-one onto machine instructions.
"""
import re, sys
from collections import Counter
from pathlib import Path

CLASSES = [
    ("fp64 fma",        re.compile(r"^fma\.rn\.f64")),
    ("fp64 mul",        re.compile(r"^mul\.rn\.f64")),
    ("fp64 add/sub",    re.compile(r"^(add|sub)\.(rn\.|rz\.)?f64")),
    ("fp64 floor/round/trunc (cvt.f64.f64)", re.compile(r"^cvt\.(rmi|rni|rzi|rpi)\.f64\.f64")),
    ("fp64 compare",    re.compile(r"^setp\.[a-z]+\.f64")),
    ("fp64 div/rcp/sqrt", re.compile(r"^(div\.rn\.f64|rcp\.rn\.f64|sqrt\.rn\.f64)")),
    ("fp64 other (neg/abs/min/max/selp)", re.compile(r"^(neg|abs|min|max|selp|mov)\.f64")),
    ("cvt f64->int64",  re.compile(r"^cvt\.rz?i?\.?(s64|u64)\.f64|^cvt\.rzi\.(s64|u64)\.f64")),
    ("cvt int64->f64",  re.compile(r"^cvt\.rn\.f64\.(s64|u64)")),
    ("cvt f64<->f32",   re.compile(r"^cvt\.(rn\.)?f32\.f64|^cvt\.f64\.f32")),
    ("cvt int32<->f64", re.compile(r"^cvt\.rn\.f64\.(s32|u32)|^cvt\.rz?i?\.?(s32|u32)\.f64")),
    ("fp32 arith/rcp",  re.compile(r"^(fma|mul|add|sub|rcp|div)\.[a-z.]*f32")),
    ("int64 shift",     re.compile(r"^(shl|shr)\.(b|s|u)64")),
    ("int64 logic",     re.compile(r"^(and|or|xor|not)\.b64")),
    ("int64 add/sub",   re.compile(r"^(add|sub)\.s64|^(add|sub)\.u64")),
    ("int64 mul/mad/div/rem", re.compile(r"^(mul|mad|div|rem)\.[a-z.]*(s64|u64)")),
    ("int64 compare/select/mov", re.compile(r"^setp\.[a-z]+\.(s64|u64|b64)|^selp\.b64|^mov\.b64|^mov\.u64|^mov\.s64")),
    ("int32 mul/mad",   re.compile(r"^(mul|mad)\.[a-z.]*(s32|u32)")),
    ("int32 div/rem",   re.compile(r"^(div|rem)\.(s32|u32)")),
    ("int32 add/sub/logic/shift", re.compile(r"^(add|sub|and|or|xor|not|shl|shr|neg|min|max)\.(s32|u32|b32)")),
    ("int32 compare/select/mov", re.compile(r"^setp\.[a-z]+\.(s32|u32|b32)|^selp\.(b32|s32|u32)|^mov\.(b32|u32|s32)|^mov\.pred|^cvt\.(u|s)(16|32|64)\.(u|s)(8|16|32|64)|^cvt\.u16|^cvt\.s16")),
    ("ld.local",        re.compile(r"^ld\.local")),
    ("st.local",        re.compile(r"^st\.local")),
    ("ld.const",        re.compile(r"^ld\.const")),
    ("ld/st.global",    re.compile(r"^(ld|st)\.global")),
    ("ld/st.shared",    re.compile(r"^(ld|st)\.shared|^atom\.shared|^bar\.sync")),
    ("ld/st.param/other mem", re.compile(r"^(ld|st)\.(param|volatile)|^ld\.[a-z]|^st\.[a-z]")),
    ("branch",          re.compile(r"^(bra|@%p\S*\s+bra)")),
    ("call",            re.compile(r"^call")),
    ("predicate logic", re.compile(r"^(and|or|xor|not)\.pred")),
]

def entry_body(text, entry):
    m = re.search(r"\.entry\s+" + re.escape(entry) + r"\s*\(", text)
    if not m:
        raise SystemExit(f"no .entry {entry}")
    start = text.index("{", m.end())
    depth = 0; i = start
    while True:
        c = text[i]
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0: break
        i += 1
    return text[start:i]

def analyse(path, entry="search"):
    text = Path(path).read_text(errors="replace")
    body = entry_body(text, entry)
    frame = re.search(r"\.local\s+\.align\s+\d+\s+\.b8\s+__local_depot\d+\[(\d+)\]", body)
    counts = Counter(); other = Counter(); total = 0
    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith(("//", ".", "$", "{", "}")) or line.endswith(":"):
            continue
        # strip predicate guard
        ins = re.sub(r"^@!?%p\d+\s+", "", line)
        if ins.startswith("bra"):
            counts["branch"] += 1; total += 1; continue
        op = ins.split()[0].rstrip(";")
        total += 1
        for name, rx in CLASSES:
            if rx.match(op):
                counts[name] += 1
                break
        else:
            other[op] += 1
    # dynamic-call check: functions called (not inlined)
    calls = Counter(re.findall(r"call\.uni\s+\(?%?\w*\)?,?\s*(\w+)", body) + re.findall(r"call\s+(\w+)", body))
    return {"entry": entry, "frame_bytes": int(frame.group(1)) if frame else 0, "total": total,
            "counts": dict(counts), "other": dict(other.most_common(12)), "calls": dict(calls)}

if __name__ == "__main__":
    r = analyse(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "search")
    print(f"{r['entry']}: {r['total']} static instructions, local frame {r['frame_bytes']} B")
    fp64 = sum(v for k, v in r["counts"].items() if k.startswith("fp64") or k.startswith("cvt f64") or k.startswith("cvt int64->f64"))
    for k, v in sorted(r["counts"].items(), key=lambda kv: -kv[1]):
        print(f"  {v:6d}  {v/r['total']*100:5.1f}%  {k}")
    print(f"  fp64-pipe class total: {fp64} ({fp64/r['total']*100:.1f}%)")
    if r["other"]: print("  other:", r["other"])
    if r["calls"]: print("  calls:", r["calls"])
