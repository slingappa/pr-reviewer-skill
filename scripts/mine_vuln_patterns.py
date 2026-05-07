#!/usr/bin/env python3
"""Mine vulnerability pattern hints from kernel-vuln style datasets.

Supports CSV and JSONL inputs with loose schema assumptions.
Outputs:
  - bug type frequency
  - top tokens from textual fields
  - suggested regex candidates for rule authoring
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter
from pathlib import Path
from typing import Dict, Iterable, Iterator, List


TEXT_KEYS = (
    "message",
    "commit_message",
    "summary",
    "description",
    "bug_type",
    "severity_hint",
    "files",
)

STOP = {
    "the",
    "and",
    "for",
    "with",
    "from",
    "that",
    "this",
    "into",
    "when",
    "where",
    "while",
    "have",
    "has",
    "use",
    "used",
    "fix",
    "fixed",
    "linux",
    "kernel",
    "commit",
}


def iter_rows(path: Path) -> Iterator[Dict[str, str]]:
    if path.suffix.lower() in {".jsonl", ".ndjson"}:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    yield {str(k): str(v) for k, v in obj.items()}
        return

    with path.open("r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            out = {}
            for k, v in row.items():
                out[str(k)] = "" if v is None else str(v)
            yield out


def tokenise(text: str) -> Iterable[str]:
    for tok in re.findall(r"[a-zA-Z_][a-zA-Z0-9_]{2,}", text.lower()):
        if tok in STOP:
            continue
        yield tok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="CSV or JSONL dataset path")
    ap.add_argument("--output", required=True, help="Output JSON summary path")
    ap.add_argument("--top-k", type=int, default=80)
    args = ap.parse_args()

    path = Path(args.input)
    bug_type_counter: Counter[str] = Counter()
    token_counter: Counter[str] = Counter()
    total = 0

    for row in iter_rows(path):
        total += 1
        btype = (row.get("bug_type") or row.get("type") or "").strip()
        if btype:
            bug_type_counter[btype] += 1

        chunk = " ".join(row.get(k, "") for k in TEXT_KEYS if k in row)
        token_counter.update(tokenise(chunk))

    top_tokens = token_counter.most_common(args.top_k)
    # Candidate patterns are lightweight seeds; final curation remains manual.
    candidates = []
    for tok, cnt in top_tokens:
        if cnt < 5:
            continue
        if tok in {"memcpy", "strcpy", "copy_from_user", "kfree", "mutex_lock", "spin_lock", "request_data"}:
            candidates.append(
                {
                    "token": tok,
                    "count": cnt,
                    "suggested_pattern": rf"\b{re.escape(tok)}\b",
                }
            )

    out = {
        "input": str(path),
        "records": total,
        "top_bug_types": bug_type_counter.most_common(40),
        "top_tokens": top_tokens,
        "candidate_patterns": candidates,
    }
    Path(args.output).write_text(json.dumps(out, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

