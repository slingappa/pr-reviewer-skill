# Kernel-Vuln Integration Plan (Implemented)

This skill now includes a 3-phase pipeline to ingest historical kernel vulnerability patterns and convert them into actionable PR-review rules.

## Phase 1: Data Ingestion + Rule Seeding

Artifacts:
- `references/kernel_vuln_rules.json`
- `scripts/mine_vuln_patterns.py`
- `scripts/apply_kernel_vuln_rules.py`

Capabilities:
- Mine bug-type/token distributions from CSV/JSONL corpora.
- Maintain machine-readable rule catalog with severity, category, risk/action guidance, source links, and confidence.
- Apply rule pack on patch added-lines and emit structured findings for `review.md`.

## Phase 2: Semantic + Benchmark Expansion

Artifacts:
- `scripts/benchmark_vuln_rules.py`
- `scripts/run_rule_benchmark.sh`
- Existing `clang` semantic pass in `scripts/generate_pr_review_report.sh`

Capabilities:
- Measure precision/recall/F1 on labeled text samples.
- Track per-rule hit density to identify noisy rules.
- Blend regex/data-derived rules with semantic analyzer findings.

## Phase 3: Governance + Continuous Quality Gates

Artifacts:
- `scripts/update_rule_metrics.py`
- `scripts/evaluate_rule_gate.py`
- `references/kernel_vuln_gate_thresholds.json`

Capabilities:
- Persist benchmark history over time.
- Enforce minimum quality gates (precision/recall/F1).
- Provide machine-readable pass/fail verdict for CI gating.
- Support profile-based staged thresholds (`seed_baseline` -> `phase2_target` -> `phase3_target`).

## Typical Workflow

1. Mine candidate patterns:
   - `python3 scripts/mine_vuln_patterns.py --input <dataset.csv|jsonl> --output outputs/patterns.json`
2. Curate `references/kernel_vuln_rules.json`.
3. Run PR review report generation (rules auto-applied).
4. Benchmark rule pack:
   - `scripts/run_rule_benchmark.sh --samples-csv <labeled_samples.csv>`
5. Update gate history:
   - `python3 scripts/update_rule_metrics.py --benchmark-json outputs/benchmark/latest_benchmark.json --history-json outputs/benchmark/history.json`
6. Evaluate named threshold profile:
   - `python3 scripts/evaluate_rule_gate.py --benchmark-json outputs/benchmark/latest_benchmark.json --history-json outputs/benchmark/history.json --thresholds-json references/kernel_vuln_gate_thresholds.json --profile seed_baseline`
