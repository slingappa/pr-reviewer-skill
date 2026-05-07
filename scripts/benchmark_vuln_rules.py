#!/usr/bin/env python3
"""Benchmark vuln rules against labeled samples.

Expected input CSV columns:
  - text (or added_line)
  - label (1 bug-introducing / risky, 0 otherwise)
Optional:
  - file
  - line
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Dict, List, Tuple


def load_rules(path: Path) -> List[dict]:
    doc = json.loads(path.read_text(encoding="utf-8"))
    return list(doc.get("rules", []))


def get_text(row: Dict[str, str]) -> str:
    for k in ("text", "added_line", "line", "content", "message"):
        if row.get(k):
            return row[k]
    return ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules-json", required=True)
    ap.add_argument("--samples-csv", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    rules = load_rules(Path(args.rules_json))
    compiled: List[Tuple[dict, re.Pattern[str], List[re.Pattern[str]]]] = []
    for r in rules:
        pat = r.get("pattern")
        if not pat:
            continue
        try:
            main_re = re.compile(str(pat))
        except re.error:
            continue
        neg = []
        for n in r.get("negative_patterns", []):
            try:
                neg.append(re.compile(str(n)))
            except re.error:
                pass
        compiled.append((r, main_re, neg))

    tp = fp = tn = fn = 0
    per_rule_hits: Dict[str, int] = {}
    rows = 0

    with Path(args.samples_csv).open("r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows += 1
            txt = get_text(row)
            label = str(row.get("label", "0")).strip()
            is_pos = label in {"1", "true", "True", "YES", "yes"}

            matched = False
            for r, main_re, neg in compiled:
                if not main_re.search(txt):
                    continue
                if any(nr.search(txt) for nr in neg):
                    continue
                matched = True
                rid = str(r.get("id", "KV-UNKNOWN"))
                per_rule_hits[rid] = per_rule_hits.get(rid, 0) + 1
            if matched and is_pos:
                tp += 1
            elif matched and not is_pos:
                fp += 1
            elif (not matched) and is_pos:
                fn += 1
            else:
                tn += 1

    precision = (tp / (tp + fp)) if (tp + fp) else 0.0
    recall = (tp / (tp + fn)) if (tp + fn) else 0.0
    f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0

    out = {
        "samples": rows,
        "tp": tp,
        "fp": fp,
        "tn": tn,
        "fn": fn,
        "precision": round(precision, 6),
        "recall": round(recall, 6),
        "f1": round(f1, 6),
        "per_rule_hits": dict(sorted(per_rule_hits.items(), key=lambda kv: kv[1], reverse=True)),
    }
    Path(args.output).write_text(json.dumps(out, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

