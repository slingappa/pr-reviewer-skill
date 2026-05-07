#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Run Phase-2 benchmark for kernel vuln rules.

Usage:
  run_rule_benchmark.sh \
    --samples-csv <path> \
    [--rules-json <path>] \
    [--out-dir <path>]

Expected sample columns:
  text,label
where label: 1 (risky) / 0 (non-risky)
USAGE
}

samples_csv=""
rules_json=""
out_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples-csv)
      samples_csv="${2:-}"
      shift 2
      ;;
    --rules-json)
      rules_json="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$samples_csv" ]] || { echo "--samples-csv is required" >&2; exit 1; }
[[ -f "$samples_csv" ]] || { echo "Missing samples csv: $samples_csv" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
rules_json="${rules_json:-$root_dir/references/kernel_vuln_rules.json}"
[[ -f "$rules_json" ]] || { echo "Missing rules json: $rules_json" >&2; exit 1; }

out_dir="${out_dir:-$root_dir/outputs/benchmark}"
mkdir -p "$out_dir"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
bench_json="$out_dir/benchmark_${ts}.json"
latest_json="$out_dir/latest_benchmark.json"

python3 "$script_dir/benchmark_vuln_rules.py" \
  --rules-json "$rules_json" \
  --samples-csv "$samples_csv" \
  --output "$bench_json"

cp -f "$bench_json" "$latest_json"
echo "Benchmark written: $bench_json"
cat "$bench_json"

