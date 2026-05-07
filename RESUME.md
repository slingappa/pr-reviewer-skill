# RESUME Guide

## 1) Re-establish repo state
```bash
cd /local/mnt/workspace/git/pr-reviewer-skill
git status --short --branch
```

Current work branch expected:
- `feat/pr-reviewer-vuln-threshold-tuning-20260507`

If starting new work, create new branch first (user requirement):
```bash
git checkout -b feat/pr-reviewer-<next-topic>-$(date +%Y%m%d)
```

## 2) Verify critical scripts compile
```bash
bash -n scripts/generate_pr_review_report.sh
python3 -m py_compile \
  scripts/apply_kernel_vuln_rules.py \
  scripts/mine_vuln_patterns.py \
  scripts/benchmark_vuln_rules.py \
  scripts/update_rule_metrics.py \
  scripts/evaluate_rule_gate.py
```

## 2.1) Verify repo-bug-model-rules assets exist
```bash
test -f references/repo-bug-model-rules.md
test -f /local/mnt/workspace/git/ml-bug-feature-extractor/models/bug_risk_pairwise_core5.joblib
```

## 3) Re-run PR review flow (reference run)
```bash
scripts/fetch_pr_review_context.sh \
  --pr-url https://github.com/riscv-software-src/librpmi/pull/78 \
  --out-dir /tmp/pr-review-librpmi-78

scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-librpmi-78 \
  --repo-dir /local/mnt/workspace/git/librpmi \
  --comment-batch-size 50 \
  --report-file /local/mnt/workspace/git/librpmi/review.md
```

Quick checks:
```bash
rg -n "Rule Matrices|Kernel-vuln rule pack ran|Kernel-vuln rule findings generated|Checkpatch Results|Proposed Review Comments|Comment Submission Batches" /local/mnt/workspace/git/librpmi/review.md
```

## 3.1) Run model-only debug mode (suppress noise)
Use this when validating only repo-specific bug-model behavior:
```bash
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /abs/path/to/local/repo \
  --base-ref <base-ref> \
  --head-ref <head-ref> \
  --allow-scope-mismatch \
  --ruleset repo-bug-model-rules \
  --bug-model /local/mnt/workspace/git/ml-bug-feature-extractor/models/bug_risk_pairwise_core5.joblib \
  --output /tmp/pr-review-123/review.md
```

Expected outputs:
- `/tmp/pr-review-123/review.md`
- `/tmp/pr-review-123/review_comments.md`

## 4) Run vulnerability mining + benchmark + gate

### Mine patterns
```bash
python3 scripts/mine_vuln_patterns.py \
  --input /tmp/kernel-vuln-data-run/kernel-vuln-data/vuln_commits.csv \
  --output /tmp/pr-review-benchmark-real/patterns_from_real_dataset.json
```

### Benchmark
```bash
scripts/run_rule_benchmark.sh \
  --samples-csv /tmp/pr-review-benchmark-real/labeled_lines_real.csv \
  --rules-json references/kernel_vuln_rules.json \
  --out-dir /tmp/pr-review-benchmark-real
```

### Gate by profile
```bash
python3 scripts/evaluate_rule_gate.py \
  --benchmark-json /tmp/pr-review-benchmark-real/latest_benchmark.json \
  --history-json /tmp/pr-review-benchmark-real/history_profile.json \
  --thresholds-json references/kernel_vuln_gate_thresholds.json \
  --profile seed_baseline
```

Profiles available:
- `seed_baseline` (current bootstrap)
- `phase2_target`
- `phase3_target`

## 5) Primary files to edit next
- Rule catalog:
  - `references/kernel_vuln_rules.json`
- Rule engine:
  - `scripts/apply_kernel_vuln_rules.py`
- Report integration:
  - `scripts/generate_pr_review_report.sh`
- Gate profiles:
  - `references/kernel_vuln_gate_thresholds.json`
- Model-only rules reference:
  - `references/repo-bug-model-rules.md`

## 6) Highest-value next work items
1. Increase recall with AST/dataflow detectors (nullability, refcount lifetime, uninitialized use).
2. Add subsystem-specific rule packs (`net/`, `drivers/`, `fs/`) from mined bug clusters.
3. Add false-positive suppression patterns + confidence calibration loop.
4. Re-benchmark and tighten from `seed_baseline` to `phase2_target`.

## 6.1) Known-5 validation replay (current benchmark)
Ground truth:
- `/tmp/pr-review-vuln5/selection.json`

Replay model-only run for all 5 canaries:
```bash
SCRIPT=/local/mnt/workspace/git/pr-reviewer-skill/scripts/generate_pr_review_report.sh
MODEL=/local/mnt/workspace/git/ml-bug-feature-extractor/models/bug_risk_pairwise_core5.joblib
ROOT=/tmp/pr-review-vuln5

find "$ROOT" -maxdepth 1 -type d -name '[0-9][0-9]_*' | sort | while read -r d; do
  base_ref=$(jq -r '.base.ref' "$d/pr.json")
  head_ref=$(jq -r '.head.ref' "$d/pr.json")
  "$SCRIPT" \
    --context-dir "$d" \
    --repo-dir /usr2/slingapp/git/linux \
    --base-ref "$base_ref" \
    --head-ref "$head_ref" \
    --allow-scope-mismatch \
    --ruleset repo-bug-model-rules \
    --bug-model "$MODEL" \
    --output "$d/review.md"
done
```

Latest verifier outputs:
- `/tmp/pr-review-vuln5/repo_bug_ruleset_eval/repo_bug_ruleset_verify.json`
- `/tmp/pr-review-vuln5/repo_bug_ruleset_eval/repo_bug_ruleset_verify.md`

Current status:
- 5/5 pass and 5/5 repeatable over 3 runs in `repo-bug-model-rules` mode.

## 7) Sync to installed skill path after changes
```bash
src=/local/mnt/workspace/git/pr-reviewer-skill
dst=/usr2/slingapp/.config/qgenie-cli/agent/skills/pr-reviewer
find "$src/scripts" -maxdepth 1 -type f -exec cp -f {} "$dst/scripts/" \;
find "$src/references" -maxdepth 1 -type f -exec cp -f {} "$dst/references/" \;
cp -f "$src/SKILL.md" "$dst/SKILL.md"
cp -f "$src/README.md" "$dst/README.md"
chmod +x "$dst/scripts"/*.sh "$dst/scripts"/*.py
```

## 8) Constraints to keep honoring
- Always create/switch to a new branch before starting work.
- Never auto-add Signed-off-by / `--signoff`; human must do final signoff.
- Keep generated review comments draft-only; human approval required before submission.
