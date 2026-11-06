#!/usr/bin/env python3
"""Recover the exact local Korean comment table; never downloads or uploads it."""
import argparse
import hashlib
from pathlib import Path
import re

SOURCE_SHA256 = "d0cdfbfe8147dd7301bb7df0bca3ecfc0fdc3f33596ceb1f804ac70f74a195db"

def extract(source: Path) -> bytes:
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError("Input is not the reviewed match review 4.0.0-beta.14 proxy DLL")
    start = data.index(b"# v3.0 Korean comments.")
    rows = []
    for line in data[start:].split(b"\n")[1:]:
        if not re.match(rb"[a-z.]+\t", line):
            break
        line.decode("utf-8", errors="strict")
        rows.append(line)
    if len(rows) != 1968:
        raise ValueError(f"Incomplete corpus: {len(rows)} rows")
    return b"\n".join(rows) + b"\n"

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dll", type=Path)
    parser.add_argument("output_tsv", type=Path)
    args = parser.parse_args()
    result = extract(args.source_dll)
    args.output_tsv.parent.mkdir(parents=True, exist_ok=True)
    args.output_tsv.write_bytes(result)
    print(f"1968 rows; sha256={hashlib.sha256(result).hexdigest()}")
