# Session Context (2026-05-07)

## Objective (Current, Explicit)
Primary end goal:
- Make `pr-reviewer-skill` consume a repo-specific trained bug model and emit bug-aware review comments that help a human reviewer catch real defects quickly.

Operational debugging mode:
- Add and use `--ruleset repo-bug-model-rules` so only model-driven findings/comments are emitted (suppress all other review noise).
- Keep default `--ruleset all` behavior unchanged for normal reviews.

Acceptance direction:
- For known vulnerable patch canaries, model-assisted reviewer output should identify bug family and produce focused review comments at localized hunks.
- Repeatability matters: outputs should be stable across reruns.

Progress:
- `[####################] 100%` for current 5-patch canary validation (repo-bug-model-rules mode).

## Current Branches
- Skill repo current branch: `feat/pr-reviewer-vuln-threshold-tuning-20260507`
- Earlier branches used in this session:
  - `feat/pr-reviewer-matrix-deepcheck-20260507`
  - `feat/pr-reviewer-vuln-phases-20260507`
- Test repo branch (`librpmi`): `review/riscv-software-src-librpmi-pr-78-20260507`

## Main Delivered Capabilities

### 1) Review generation core
- Expanded rule matrices in `review.md` across 9 research groups.
- Added dedicated Linux coding-style matrix with rule links.
- Added rule-linked draft comments (`Rule:` + `Source:`).

### 2) Checkpatch and comment workflow
- Removed fixed inline-comment cap.
- Added configurable `--checkpatch-inline-cap` (default `0` = unlimited).
- Added `--comment-batch-size` and deterministic section:
  - `## 11. Comment Submission Batches (Human Gate)`
- Ensured all draft comments are printed (removed truncation to first 220 lines).

### 3) Human-comment parity refinements
Added autonomous detectors for:
- callback null-guard risk
- callback error-return contract weakness
- raw request payload forwarding without local decode
- request length (`request_datalen`) not used for validation
- constant success return / swallowed callback status
- missing nearby `\defgroup`
- naming drift (`do_set_logging` vs local `*_set_state` convention)
- typed callback recommendation (decoded parameters)

### 4) Kernel-vuln 3-phase integration
Implemented all phases in skill repo:

#### Phase 1
- `references/kernel_vuln_rules.json` (machine-readable rule pack)
- `scripts/mine_vuln_patterns.py`
- `scripts/apply_kernel_vuln_rules.py`
- Integrated into `generate_pr_review_report.sh` (auto-run when available)

#### Phase 2
- `scripts/benchmark_vuln_rules.py`
- `scripts/run_rule_benchmark.sh`
- Existing clang semantic pass retained and reported

#### Phase 3
- `scripts/update_rule_metrics.py`
- `scripts/evaluate_rule_gate.py`
- `references/kernel_vuln_gate_thresholds.json` (profiles)

### 5) Repo-specific bug model integration (`repo-bug-model-rules`)
Implemented in `scripts/generate_pr_review_report.sh`:
- New CLI options for model-assisted scoring and gating:
  - `--bug-model`
  - `--bug-scorer-cmd`
  - `--bug-binary-threshold`
  - `--bug-family-threshold`
  - `--bug-hunk-threshold`
  - `--bug-topk-hunks`
  - `--ruleset all|repo-bug-model-rules`
- Added focused fast path:
  - `run_repo_bug_model_rules_only`
  - Runs only model scorer, gates signal, emits focused `review.md` and `review_comments.md`.
  - Suppresses generic heuristic/process findings in this mode.
- Added rule reference doc:
  - `references/repo-bug-model-rules.md`
- Added README/SKILL usage docs for model-only mode.

Model artifact currently used:
- `/local/mnt/workspace/git/ml-bug-feature-extractor/models/bug_risk_pairwise_core5.joblib`

## Latest Validation (Known Vulnerable 5-Patch Canary)
Evaluation root:
- `/tmp/pr-review-vuln5`

Focused ruleset output snapshot:
- `/tmp/pr-review-vuln5/repo_bug_ruleset_eval`

Verification artifacts:
- `/tmp/pr-review-vuln5/repo_bug_ruleset_eval/repo_bug_ruleset_verify.json`
- `/tmp/pr-review-vuln5/repo_bug_ruleset_eval/repo_bug_ruleset_verify.md`

Results (repo-bug-model-rules mode):
- 5/5 cases passed bug-family match + `actual-bug` mode + comment generation.
- 5/5 cases repeatable across 3 reruns.
- Families matched all 5 expected labels:
  - use-after-free
  - null-deref
  - out-of-bounds
  - race-condition
  - deadlock

## Research/Benchmark Findings
- Dataset used: `https://github.com/quguanni/kernel-vuln-data`
- Local clone: `/tmp/kernel-vuln-data-run/kernel-vuln-data`
- High-frequency bug classes observed include:
  - crash, hang, null-deref, error-handling, use-after-free,
  - memory-leak, uninitialized, refcount, deadlock, out-of-bounds,
  - race-condition, double-free, integer-overflow, divide-by-zero, signedness

### Real-data benchmark snapshots
- Subject-level benchmark had very low recall (not representative for code-line rules).
- Line-level benchmark (introducing-commit added lines vs random Linux commits):
  - precision ~0.50
  - recall ~0.0067
  - f1 ~0.0133
- Interpretation: seed rules are precise-ish but recall is still early-stage (needs AST/dataflow/subsystem packs).

## Current Rule Pack Status
`kernel_vuln_rules.json` now includes 28 rules, including added families:
- memleak, refcount symmetry, potential double free
- race window / deadlock nested lock patterns
- divide-by-zero, signedness, info leak
- missing-check hints
- naming consistency heuristic

## Test PR used throughout
- PR: `https://github.com/riscv-software-src/librpmi/pull/78`
- Local report: `/local/mnt/workspace/git/librpmi/review.md`
- Latest outputs include:
  - full matrix section
  - full checkpatch counts and inline draft coverage
  - batched comment plan
  - kernel-vuln findings section metrics

## Installed Skill Sync
Installed path synced repeatedly:
- `/usr2/slingapp/.config/qgenie-cli/agent/skills/pr-reviewer/`
  - `scripts/*`
  - `references/*`
  - `SKILL.md`, `README.md`

## Notable Remaining Technical Debt
- Recall is still low for vulnerability discovery from lexical rules alone.
- Next biggest lift is semantic/AST/dataflow enrichment per subsystem.
- Some heuristics are intentionally low-confidence and may need suppressions/tuning.
- Model canary is strong, but broader generalization still requires larger clean benchmarks and harder negatives per repo.
