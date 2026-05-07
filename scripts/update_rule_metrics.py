#!/usr/bin/env python3
"""Phase-3 metric tracking and gating for vuln rule performance."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--benchmark-json", required=True)
    ap.add_argument("--history-json", required=True)
    ap.add_argument("--min-precision", type=float, default=0.45)
    ap.add_argument("--min-recall", type=float, default=0.30)
    ap.add_argument("--min-f1", type=float, default=0.35)
    args = ap.parse_args()

    bench = json.loads(Path(args.benchmark_json).read_text(encoding="utf-8"))
    hist_path = Path(args.history_json)
    if hist_path.exists():
        hist = json.loads(hist_path.read_text(encoding="utf-8"))
        if not isinstance(hist, list):
            hist = []
    else:
        hist = []

    entry: Dict[str, Any] = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "precision": float(bench.get("precision", 0.0)),
        "recall": float(bench.get("recall", 0.0)),
        "f1": float(bench.get("f1", 0.0)),
        "samples": int(bench.get("samples", 0)),
        "tp": int(bench.get("tp", 0)),
        "fp": int(bench.get("fp", 0)),
        "tn": int(bench.get("tn", 0)),
        "fn": int(bench.get("fn", 0)),
        "top_rules": bench.get("per_rule_hits", {}),
    }
    hist.append(entry)
    hist_path.parent.mkdir(parents=True, exist_ok=True)
    hist_path.write_text(json.dumps(hist, indent=2), encoding="utf-8")

    gate_ok = (
        entry["precision"] >= args.min_precision
        and entry["recall"] >= args.min_recall
        and entry["f1"] >= args.min_f1
    )
    verdict = {
        "gate_ok": gate_ok,
        "thresholds": {
            "min_precision": args.min_precision,
            "min_recall": args.min_recall,
            "min_f1": args.min_f1,
        },
        "current": {
            "precision": entry["precision"],
            "recall": entry["recall"],
            "f1": entry["f1"],
            "samples": entry["samples"],
        },
        "history_entries": len(hist),
    }
    print(json.dumps(verdict, indent=2))
    return 0 if gate_ok else 3


if __name__ == "__main__":
    raise SystemExit(main())

