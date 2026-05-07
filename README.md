# pr-reviewer skill repo

This repository packages the `pr-reviewer` Codex skill as a standalone installable bundle.

## What this skill does

The skill helps you:
1. Fetch real PR review context from GitHub (PR metadata, files, review comments, issue comments, reviews, commits).
2. Correlate fetched PR data with a local checked-out repository.
3. Generate a structured `review.md` with autonomous prioritized findings from patch analysis.
4. Optionally auto-detect and run repo checkpatch (or use explicit command) and include warning/error summary.
5. Treat existing reviewer comments as context only.
6. Include an extensive cross-repo review-topic coverage matrix (API/ABI, tests, docs, CI, dependencies, security, migration, release impact, ownership/compliance).
7. Include open questions, validation commands, and reviewer-response workflow.

The review-topic model is based on patterns seen in Linux/QEMU/EDK2/U-Boot plus generic practices from popular multi-language ecosystems (Go, Python, Kubernetes, Node.js, and Google code review guidance).

The skill now enforces explicit grouped task checks from:
- Linux kernel submission checklist/process
- QEMU submitting patches workflow
- Python core PR acceptance workflow
- Kubernetes PR/review process
- Google code review standard
- Go code review comments
- Node.js PR responsibilities/workflow
- Rust API guideline checklist mindset
- OWASP secure code review framing

Each task is marked as `pass`, `attention`, or `needs-input`.
It also emits dedicated per-group **Rule Matrices** with source links for each rule.

Deep-crawl reference catalog:
- [`references/research_task_catalog.md`](references/research_task_catalog.md)
- This file contains expanded sublink-derived checks per source group and is used to avoid shallow topic coverage.

## Repository layout

- `install.sh`: installer for the skill
- `SKILL.md`: skill instructions
- `agents/openai.yaml`: UI metadata
- `scripts/fetch_pr_review_context.sh`: fetch PR review context artifacts
- `scripts/generate_pr_review_report.sh`: generate structured `review.md`
- `scripts/mine_vuln_patterns.py`: mine dataset pattern candidates (Phase 1)
- `scripts/apply_kernel_vuln_rules.py`: apply curated vuln rules to patch lines (Phase 1)
- `scripts/benchmark_vuln_rules.py`: compute precision/recall/F1 on labeled samples (Phase 2)
- `scripts/run_rule_benchmark.sh`: benchmark wrapper (Phase 2)
- `scripts/update_rule_metrics.py`: update history + gate verdict (Phase 3)
- `scripts/evaluate_rule_gate.py`: evaluate benchmark with named threshold profile (Phase 3)
- `references/kernel_vuln_rules.json`: machine-readable vulnerability rule set
- `references/kernel_vuln_phase_plan.md`: phase-by-phase integration details
- `references/kernel_vuln_gate_thresholds.json`: staged gate profiles

## Clone

SSH (recommended for private repo access):

```bash
GIT_SSH_COMMAND='ssh -i ~/.ssh/slingappa_git/id_rsa -o IdentitiesOnly=yes' \
git clone git@github.com:<your-org>/pr-reviewer-skill.git
cd pr-reviewer-skill
```

HTTPS:

```bash
git clone https://github.com/<your-org>/pr-reviewer-skill.git
cd pr-reviewer-skill
```

Checkout latest main:

```bash
git checkout main
git pull --ff-only
```

## Install

```bash
./install.sh --force
```

Optional destination:

```bash
./install.sh --dest /path/to/skills --force
```

## Required inputs when invoking skill

Provide these in your prompt:
1. Local repo folder path
2. PR URL (or owner/repo + PR number)

## Recommended prompt template

```text
Use $pr-reviewer.
Repo: /abs/path/to/local/repo.
PR: https://github.com/<owner>/<repo>/pull/<number>.
Fetch latest PR metadata/files/comments/reviews and generate review.md with prioritized findings (high/medium/low), risk statements, file references, open questions, and validation commands.
```

## Script usage

```bash
# 0) Create and switch to a dedicated branch first (mandatory)
git -C /abs/path/to/local/repo switch -c pr-<number>-review

# 1) Fetch PR context artifacts
./scripts/fetch_pr_review_context.sh \
  --pr-url https://github.com/<owner>/<repo>/pull/<number> \
  --out-dir /tmp/pr-review-<number>

# 2) Generate review report using local checkout
./scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-<number> \
  --repo-dir /abs/path/to/local/repo \
  --comment-batch-size 50 \
  --report-file /abs/path/to/local/repo/review.md

# Optional: provide explicit checkpatch command when available
./scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-<number> \
  --repo-dir /abs/path/to/local/repo \
  --checkpatch-cmd "./scripts/checkpatch.pl --no-tree" \
  --report-file /abs/path/to/local/repo/review.md
```

## Notes

- If GitHub API rate-limit/auth blocks fetch, export `GITHUB_TOKEN` or pass `--token`.
- Checkpatch command is auto-detected in common locations (`scripts/checkpatch.pl`, `BaseTools/Scripts/PatchCheck.py`).
- If checker is not in target repo, skill infers style family and fetches appropriate checker from internet (Linux `checkpatch.pl` or EDK2 `PatchCheck.py`).
- If family inference is ambiguous, report includes a hint to pass `--style-family` or `--checkpatch-cmd`.
- Base ref auto-selection prefers upstream target first when available (`upstream/<base>` before `origin/<base>`), reducing fork-remote scope mismatches.
- Generator is strict by default:
- local diff scope must match fetched PR files (override with `--allow-scope-mismatch`)
- checkpatch is optional and reported when detected/provided
- `review.md` now includes a "Proposed Review Comments (Human Approval Required)" section with draft line comments generated from autonomous findings.
- Draft review comments include rule IDs/source links where mapping is available.
- checkpatch warnings/errors are converted into file/line draft inline comments (capped) so they are review-ready instead of only summarized.
- checkpatch-derived draft comment cap defaults to unlimited; override with `--checkpatch-inline-cap <n>`.
- comment submission batches are planned in report section 11; tune with `--comment-batch-size <n>`.
- kernel-vuln historical-rule pack runs automatically when Python is available and contributes additional findings.
- Do not auto-submit proposed comments; a human must approve/edit each before posting.
- Always start by creating a new local branch dedicated to this review task.
- Do not add `Signed-off-by:` automatically; final signoff must always be done by a human.
- The report is signal-driven; it should be combined with manual code reasoning before final approval.
- If local base/head refs differ from defaults, pass `--base-ref` and `--head-ref` explicitly.

## Vulnerability Rule Lifecycle (3 phases)

```bash
# Phase 1: mine candidate patterns from vuln corpora
python3 scripts/mine_vuln_patterns.py \
  --input /path/to/kernel_vuln_dataset.csv \
  --output outputs/patterns.json

# Phase 2: benchmark curated rules on labeled samples
scripts/run_rule_benchmark.sh \
  --samples-csv /path/to/labeled_samples.csv \
  --out-dir outputs/benchmark

# Phase 3: update historical metrics and enforce gate
python3 scripts/update_rule_metrics.py \
  --benchmark-json outputs/benchmark/latest_benchmark.json \
  --history-json outputs/benchmark/history.json \
  --min-precision 0.45 \
  --min-recall 0.30 \
  --min-f1 0.35

# Phase 3 (profile-based): evaluate against staged thresholds
python3 scripts/evaluate_rule_gate.py \
  --benchmark-json outputs/benchmark/latest_benchmark.json \
  --history-json outputs/benchmark/history.json \
  --thresholds-json references/kernel_vuln_gate_thresholds.json \
  --profile seed_baseline
```
