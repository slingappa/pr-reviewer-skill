#!/usr/bin/env python3
"""Evaluate benchmark against named threshold profile."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--benchmark-json", required=True)
    ap.add_argument("--history-json", required=True)
    ap.add_argument("--thresholds-json", required=True)
    ap.add_argument("--profile", default="seed_baseline")
    args = ap.parse_args()

    doc = json.loads(Path(args.thresholds_json).read_text(encoding="utf-8"))
    prof = (doc.get("profiles") or {}).get(args.profile)
    if not prof:
        print(f"error: profile not found: {args.profile}", file=sys.stderr)
        return 2

    cmd = [
        sys.executable,
        str(Path(__file__).with_name("update_rule_metrics.py")),
        "--benchmark-json",
        args.benchmark_json,
        "--history-json",
        args.history_json,
        "--min-precision",
        str(prof["min_precision"]),
        "--min-recall",
        str(prof["min_recall"]),
        "--min-f1",
        str(prof["min_f1"]),
    ]
    return subprocess.call(cmd)


if __name__ == "__main__":
    raise SystemExit(main())

