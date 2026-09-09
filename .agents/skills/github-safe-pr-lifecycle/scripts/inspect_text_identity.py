#!/usr/bin/env python3
"""Report text identity and newline metadata without exposing input content."""

from __future__ import annotations

import argparse
import base64
import codecs
import hashlib
import json
from pathlib import Path
import sys
from typing import Optional, Tuple


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inspect UTF-8 text identity without modifying or printing the input."
    )
    parser.add_argument(
        "--file",
        type=Path,
        help="Read binary input from this file; omit to read stdin.",
    )
    parser.add_argument(
        "--normalize-lf",
        action="store_true",
        help="Inspect an in-memory CRLF/lone-CR to LF normalization.",
    )
    return parser.parse_args()


def read_input(path: Optional[Path]) -> bytes:
    if path is None:
        return sys.stdin.buffer.read()
    return path.read_bytes()


def newline_counts(data: bytes) -> Tuple[int, int, int]:
    crlf_count = data.count(b"\r\n")
    lone_lf_count = data.count(b"\n") - crlf_count
    lone_cr_count = data.count(b"\r") - crlf_count
    return crlf_count, lone_lf_count, lone_cr_count


def main() -> int:
    args = parse_args()
    try:
        data = read_input(args.file)
    except OSError as error:
        print(f"input error: {error}", file=sys.stderr)
        return 2

    if args.normalize_lf:
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")

    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        print(f"UTF-8 decode error: {error}", file=sys.stderr)
        return 2

    crlf_count, lone_lf_count, lone_cr_count = newline_counts(data)
    result = {
        "base64_length": len(base64.b64encode(data)),
        "bom": data.startswith(codecs.BOM_UTF8),
        "character_count": len(text),
        "crlf_count": crlf_count,
        "lone_cr_count": lone_cr_count,
        "lone_lf_count": lone_lf_count,
        "sha256": hashlib.sha256(data).hexdigest(),
        "trailing_newline": data.endswith((b"\n", b"\r")),
        "utf8_byte_count": len(data),
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
