---
name: pr-reviewer
description: Review a GitHub pull request using the PR URL and a local checked-out repo path, then generate a concrete `review.md` plus a submittable `review_comments.md` with prioritized findings and ready-to-post draft comments.
---

# PR Reviewer

## Overview

Use this skill to perform a structured PR review from real GitHub data plus local repo context. It fetches PR metadata/files/comments/reviews, correlates with local branch/diff state, and generates:
- an implementation-ready full report (`review.md`) with prioritized findings and process evidence
- a concise, submittable draft-comment file (`review_comments.md`) for human-approved posting

Primary intent: replace human reviewer first-pass by generating autonomous, code-level review findings from patch content. Existing reviewer comments are treated as secondary context by default.

Topic model is intentionally broad and cross-repo, inspired by common review expectations seen in large OSS ecosystems (for example kernel/hypervisor/firmware plus mainstream multi-language repositories).
Baseline references include Linux/QEMU/EDK2/U-Boot style-process guidance and generic review practices from ecosystems like Go, Python, Kubernetes, Node.js, and Google engineering review docs.
The skill must remain generic: avoid repo-specific assumptions and derive checks from observed repo language/tooling plus PR evidence.

## Research Basis Groups

Treat each source below as a distinct review-task group with actionable checks:
1. Linux kernel submission checklist/process checks
2. QEMU submitting-a-patch workflow expectations
3. Python core PR acceptance/check workflow
4. Kubernetes PR/review process practices
5. Google code review standard (code health)
6. Go code review comments norms
7. Node.js PR/review workflow responsibilities
8. Rust API guideline checklist mindset
9. OWASP secure code review framing

For every run, produce explicit per-group tasks with status:
- `pass`: evidence exists in patch/context
- `attention`: likely gap or risk from available signals
- `needs-input`: cannot be proven from local/PR data; requires human confirmation

Deep-crawl task catalog:
- [`references/research_task_catalog.md`](references/research_task_catalog.md)
- This catalog is mandatory input for topic-group checks and should be kept in sync with upstream guidance changes.

Historical vulnerability rule corpus integration:
- [`references/kernel_vuln_rules.json`](references/kernel_vuln_rules.json)
- [`references/kernel_vuln_phase_plan.md`](references/kernel_vuln_phase_plan.md)
- [`references/kernel_vuln_gate_thresholds.json`](references/kernel_vuln_gate_thresholds.json)
- Use this as an additional autonomous signal source (not replacing semantic/manual reasoning).

## Required Inputs

Request these inputs before starting review:
1. Local repo folder path (checked-out repository)
2. PR details
   - Preferred: full PR URL
   - Acceptable fallback: owner/repo + PR number

Optional but recommended:
3. GitHub token (for private repos or rate-limit resilience)
4. Base/head refs if local branch naming does not match remote defaults
5. Explicit checkpatch command if repo uses a non-standard checker path

If repo path or PR details are missing, ask for them explicitly.

## Unattended Hardening Defaults

- Default to fully unattended execution once mandatory inputs are present.
- Ask the user only when a mandatory gate cannot be satisfied from local or fetched data.
- Ask at most one concise blocking question at a time, with the exact missing datum.
- Never fabricate uncertain facts; mark as `needs-input` when evidence cannot be established.
- Keep a short run log in the report: what was fetched, what was inferred, what was validated, and what remains uncertain.
- Never leak secrets in logs or artifacts (tokens, cookies, private URLs with credentials).

## Workflow

1. Create a dedicated working branch first (mandatory)
   - Before any fetch/review/edit actions, create and switch to a new local branch.
   - Suggested naming: `pr-<number>-review` or `review/<owner>-<repo>-pr-<number>`.
   - Keep the branch focused on the current PR review task only.

2. Enter repo and validate context
   - Confirm repo exists and `.git` is present.
   - Capture branch, remotes, and worktree status.
   - Verify PR owner/repo matches at least one configured remote (or clearly document mismatch).

3. Fetch actual PR review context from GitHub API
   - `GET /repos/{owner}/{repo}/pulls/{number}`
   - `GET /repos/{owner}/{repo}/pulls/{number}/files`
   - `GET /repos/{owner}/{repo}/pulls/{number}/comments`
   - `GET /repos/{owner}/{repo}/issues/{number}/comments`
   - `GET /repos/{owner}/{repo}/pulls/{number}/reviews`
   - `GET /repos/{owner}/{repo}/pulls/{number}/commits`
   - Handle pagination for all list endpoints until completion.
   - Retry transient API/network failures with bounded backoff before declaring failure.
   - Record fetch counts per endpoint and note if any endpoint response is partial or unavailable.

4. Build review findings
   - Prioritize autonomous findings from patch content and local validation first.
   - Prioritize by severity:
     - `high`: blocking correctness/regression/release risk
     - `medium`: likely bug/maintainability/testing gap
     - `low`: style/docs/minor polish
   - Classify each finding:
     - `correctness`
     - `testing-gap`
     - `maintainability`
     - `process`
   - Map each finding to file/line where available.
   - For `high` and `medium` findings, require explicit evidence (diff snippet, API metadata, or local command output).
   - Merge duplicate findings that point to the same root cause.
   - Avoid low-value noise: style-only comments should be emitted only when backed by project policy/checker output.

5. Generate review artifacts (`review.md` and `review_comments.md`)
   - Include PR snapshot and changed-file scope.
   - Include a dedicated per-group **Rule Matrix** section with per-rule status (`pass`/`attention`/`needs-input`) and source links.
   - Include exhaustive research-derived task groups and actionable task checks for all groups listed in `Research Basis Groups`.
   - Ensure each group includes sublink-derived checks from `references/research_task_catalog.md` (not only top-level summary checks).
   - Include autonomous findings ordered by severity.
   - Include existing reviewer comments as context only (not primary findings).
   - Include checkpatch command used and warning/error summary.
   - Include open questions and assumptions.
   - Include exact validation commands for local reruns.
   - Include suggested reviewer response workflow.
   - Generate `review_comments.md` containing only post-ready draft comments (no long matrices/checklists), one comment block per finding with severity and file/line.
   - Include a compact `Open Questions` subsection in `review_comments.md` for unresolved assumptions that may change comment disposition.

### Mandatory Gates

- Input gate: repo path and PR identity must be present and parseable.
- Identity gate: fetched PR owner/repo must match intended local repo or be explicitly flagged as mismatch.
- Fetch completeness gate: required PR endpoints must be fetched successfully, including pagination.
- PR scope gate (default strict): local diff file set (`base...head`) must match fetched GitHub PR file set.
- Diff fidelity gate: verify local base/head resolution uses merge-base semantics; document exact refs used.
- Large/binary coverage gate: if GitHub omits patch text for files, mark limitation and use local `git diff` where possible.
- Evidence gate: every `high` or `medium` finding must include concrete evidence and a falsifiable risk statement.
- Uncertainty gate: uncertain claims must be downgraded to `needs-input` (never presented as confirmed defects).
- Draft-comment gate: generated comments must be deduplicated and directly actionable.
- Checkpatch is optional by default for cross-repo compatibility. If available, run and report it.
- Checker resolution order:
  - use checker in target repo if present
  - infer style family from repo + patch/review signals
  - fetch corresponding checker from internet when family is confident
  - if family is ambiguous, request user hint (`--style-family` or `--checkpatch-cmd`)
- Base ref auto-resolution order (when `--base-ref` is omitted):
  - `upstream/<pr-base-branch>`
  - `origin/<pr-base-branch>`
  - `<pr-base-branch>`
  - common fallbacks: `upstream/main`, `upstream/master`, `origin/main`, `origin/master`, `main`, `master`
- Override flags only when intentionally needed:
  - `--allow-scope-mismatch`

### Autonomous Fallback Order

- If strict scope gate fails, auto-fetch/update refs and recompute once before escalating.
- If checker discovery fails, continue semantic review and mark checker status as `needs-input` instead of aborting.
- If remote data is rate-limited or partially unavailable, continue with available evidence and clearly label confidence.
- Abort only when mandatory inputs are missing or PR identity cannot be resolved.

6. Keep output action-oriented
   - Each finding must include:
     - location
     - evidence/source
     - risk statement
     - recommended action

## Commit and Signoff Policy

- Never add `Signed-off-by:` trailers automatically in any commit message.
- Never use `git commit --signoff` while operating this skill.
- If signoff is required by project policy, leave it to a human to add final signoff manually.

## Output Contract

When complete, outputs must include:

### A) `review.md` (full report)
1. PR metadata summary (owner/repo/number/title/base/head)
2. Actual fetched artifact counts and fetch timestamp
3. Changed files summary with additions/deletions
4. Extensive review-topic coverage section
   - Must include all 9 research basis groups and multiple actionable tasks per group.
   - Must mark each task as `pass` / `attention` / `needs-input`.
   - Must include per-group rule matrices with exact source links.
5. Prioritized findings with file references
   - Include confidence level (`high`/`medium`/`low`) for each finding.
6. Existing reviewer context section (secondary signal)
7. Open questions / assumptions
8. Validation commands for local rerun
9. Checkpatch results section (command, mode, warnings/errors, snippet)
10. Proposed review comments section (draft only, human-approval required)
   - Each generated draft comment should include the originating rule ID and source link where available.
11. Reviewer-response workflow (comment/approve/request changes)

### B) `review_comments.md` (submittable draft-only comments)
1. Short PR header (repo/PR number/title)
2. One comment block per finding, ordered by severity
3. Each block must include:
   - stable comment id (for reviewer tracking, deterministic from file+line+category+summary hash)
   - severity (`HIGH`/`MEDIUM`/`LOW`)
   - location (file + line)
   - final draft comment text suitable for direct posting
4. Keep this file concise: no rule matrix, no large checkpatch logs, no generic checklist noise
5. Include a one-line human gate reminder: comments are draft-only until reviewer approval
6. Include `Open Questions` (if any) as short, reviewer-facing prompts tied to specific findings

## Human Gate for Review Comments

- Any generated review comment text is draft-only by default.
- Do not auto-submit generated comments to GitHub.
- A human reviewer must approve/edit each proposed comment before posting.
- Treat `review_comments.md` as the preferred posting queue for human-approved comments.
- When checkpatch reports issues, generate file/line draft inline comments from those findings (with cap), and keep full counts visible in the report.
- Default checkpatch inline cap is unlimited; use `--checkpatch-inline-cap <n>` only when intentionally constraining volume.
- Group generated comments into submission batches and require human approval per batch before posting.

## Command Patterns

Use one of these:
1. `curl` + GitHub REST API
2. `gh api` / `gh pr view` if authenticated

Use `jq` to normalize JSON into concise tables.

## Bundled Scripts

Use [`scripts/fetch_pr_review_context.sh`](scripts/fetch_pr_review_context.sh) to fetch PR artifacts.

Examples:
```bash
# Using PR URL
scripts/fetch_pr_review_context.sh \
  --pr-url https://github.com/org/repo/pull/123 \
  --out-dir /tmp/pr-review-123

# Using owner/repo/number
scripts/fetch_pr_review_context.sh \
  --owner org \
  --repo repo \
  --pr 123 \
  --out-dir /tmp/pr-review-123
```

Use [`scripts/generate_pr_review_report.sh`](scripts/generate_pr_review_report.sh) to generate `review.md`.
Then generate `review_comments.md` as a concise companion artifact from validated findings (not raw/noisy heuristic output).

Examples:
```bash
# Print report to stdout
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /path/to/repo

# Write report file
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /path/to/repo \
  --output /tmp/pr-review-123/review.md

# Optional: add explicit checkpatch command when repo has one
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /path/to/repo \
  --checkpatch-cmd "./scripts/checkpatch.pl --no-tree" \
  --output /tmp/pr-review-123/review.md

# Optional: tune draft comment batching/checkpatch volume
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /path/to/repo \
  --comment-batch-size 50 \
  --checkpatch-inline-cap 0 \
  --output /tmp/pr-review-123/review.md

# Optional: evaluate only repo bug-model rules (suppress other noise)
# If ml-bug-feature-models is installed, --bug-model/--bug-scorer-cmd are auto-detected.
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /path/to/repo \
  --base-ref <base-ref> \
  --head-ref <head-ref> \
  --ruleset repo-bug-model-rules \
  --output /tmp/pr-review-123/review.md

# Overwrite repo review.md
scripts/generate_pr_review_report.sh \
  --context-dir /tmp/pr-review-123 \
  --repo-dir /path/to/repo \
  --report-file /path/to/repo/review.md
```

Rule reference for bug-model-only mode:
- [`references/repo-bug-model-rules.md`](references/repo-bug-model-rules.md)
- Auto-detection sources for installed model bundles:
  - `~/.config/pr-reviewer-skill/bug-model.env`
  - `ml-bug-feature-models/current`

Vulnerability-rule lifecycle scripts:
```bash
# Phase 1: mine candidate patterns from vulnerability dataset
python3 scripts/mine_vuln_patterns.py \
  --input /path/to/dataset.csv \
  --output /tmp/vuln-patterns.json

# Phase 2: benchmark curated rules on labeled samples
scripts/run_rule_benchmark.sh \
  --samples-csv /path/to/labeled_samples.csv \
  --out-dir /tmp/pr-review-benchmark

# Phase 3: update historical metrics and apply gate thresholds
python3 scripts/update_rule_metrics.py \
  --benchmark-json /tmp/pr-review-benchmark/latest_benchmark.json \
  --history-json /tmp/pr-review-benchmark/history.json \
  --min-precision 0.45 --min-recall 0.30 --min-f1 0.35

# Phase 3 (profile mode): evaluate named gate profile
python3 scripts/evaluate_rule_gate.py \
  --benchmark-json /tmp/pr-review-benchmark/latest_benchmark.json \
  --history-json /tmp/pr-review-benchmark/history.json \
  --thresholds-json references/kernel_vuln_gate_thresholds.json \
  --profile seed_baseline
```
