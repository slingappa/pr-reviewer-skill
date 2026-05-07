# repo-bug-model-rules

Purpose:
- Run only repository-specific bug-model checks and suppress broader heuristic/process noise.

Activation:
- Pass `--ruleset repo-bug-model-rules` to `scripts/generate_pr_review_report.sh`.
- Model path can be supplied with `--bug-model <path>`, or auto-detected from:
  - `~/.config/pr-reviewer-skill/bug-model.env`
  - `ml-bug-feature-models/current` bundle layout.

Behavior:
1. Scores the target patch/commit using the configured bug scorer.
2. Applies gated decision logic:
   - binary risk threshold
   - bug-family threshold
   - hunk/localization threshold
3. Emits only model-driven findings and review comments:
   - `REPO-BUG-MODEL-RULE-1`: actual-bug gated signal
   - `REPO-BUG-MODEL-RULE-2`: risk-only signal
   - `REPO-BUG-MODEL-RULE-3`: no strong model signal

Outputs:
- Focused `review.md` containing:
  - model configuration and scores
  - predicted bug family
  - top localized hunk
  - model-generated prioritized finding(s)
- Focused `review_comments.md` with draft inline comments only from model findings.

Default mode:
- `--ruleset all` (default) keeps full cross-ecosystem review behavior and includes model findings as an extra signal when `--bug-model` is provided.
