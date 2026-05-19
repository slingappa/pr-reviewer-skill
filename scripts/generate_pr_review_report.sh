#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate a structured review.md from fetched GitHub PR context + local repo state.

Usage:
  generate_pr_review_report.sh --context-dir <dir> --repo-dir <dir> [options]

Options:
  --context-dir <dir>   Directory containing fetched PR artifacts (required)
  --repo-dir <dir>      Local checked-out repo path (required)
  --base-ref <ref>      Base ref used for local diff checks (default: upstream/<base> then origin/<base>)
  --head-ref <ref>      Head ref for local diff checks (default: HEAD)
  --checkpatch-cmd <cmd> Explicit checkpatch command/prefix (auto-detected if omitted)
  --style-family <name> Style family hint: auto|linux|qemu|uboot|edk2|generic
  --checkpatch-inline-cap <n> Max checkpatch-derived inline drafts (0 = unlimited; default: 0)
  --comment-batch-size <n> Number of approved comments per submission batch (default: 50)
  --cross-ecosystem-mode <mode> Rule/report breadth: repo-aware|full (default: repo-aware)
  --bug-model <path>    Path to bug model artifact (pairwise model). Optional if auto-detected from installed ml-bug-feature-models.
  --bug-scorer-cmd <cmd> Scorer command prefix. Optional if auto-detected from bundle runtime.
  --bug-binary-threshold <n> Binary risk threshold for model gating (default: 0.45)
  --bug-family-threshold <n> Bug family threshold for model gating (default: 0.35)
  --bug-hunk-threshold <n> Hunk/localization threshold for model gating (default: 0.35)
  --bug-high-risk-fallback-threshold <n> Inject a high-risk fallback draft comment when model is actual-bug but all line comments are filtered (default: 0.90)
  --bug-guarded-risk-min-hunk <n> Min top-hunk confidence to anchor risk-only manual-check comments to file:line (default: 0.20)
  --bug-risk-only-fallback-threshold <n> Optional fallback for risk-only mode when all line comments are filtered (disabled by default)
  --bug-topk-hunks <n>  Number of top hunks to request from model scorer (default: 5)
  --ruleset <name>      Rule selection: all|repo-bug-model-rules (default: all)
  --no-fetch-checkpatch Disable remote fetch fallback when local checker is missing
  --allow-scope-mismatch Do not fail when local diff file set differs from GitHub PR file set
  --output <file>       Write report to file (default: stdout)
  --report-file <file>  Overwrite this report file directly
  --include-clean       Include explicit low-severity clean findings when no blockers are detected
  -h, --help            Show help

Environment (optional model auto-detect override):
  BUG_MODEL_PATH=/abs/path/to/default_model.joblib
  BUG_SCORER_CMD=/abs/path/to/install.sh --score-pairwise
  BUG_MODEL_PATH_<REPO>=/abs/path/to/repo_specific_model.joblib   (example: BUG_MODEL_PATH_LINUX, BUG_MODEL_PATH_EDK2)
  BUG_SCORER_CMD_<REPO>=/abs/path/to/install.sh --score-pairwise

Environment (optional external YAML rules):
  EXTERNAL_YAML_ENGINE=semgrep
  EXTERNAL_YAML_CONFIG=/abs/path/to/semgrep_rules.yml
  EXTERNAL_GITLAB_SAST_RULESET=/abs/path/to/sast-ruleset.toml
  EXTERNAL_DATADOG_RULES=/abs/path/to/datadog_rules.yml
  EXTERNAL_YAML_WINDOW=3
  EXTERNAL_YAML_SEMGREP_SCAN_TIMEOUT_SEC=45
  EXTERNAL_YAML_SEMGREP_RULE_TIMEOUT_SEC=3
  EXTERNAL_YAML_SEMGREP_TIMEOUT_THRESHOLD=1
  EXTERNAL_YAML_SEMGREP_MAX_TARGET_BYTES=1000000
  EXTERNAL_YAML_SEMGREP_JOBS=4
  EXTERNAL_YAML_CLANG_TIDY_CHECKS=clang-analyzer-*,cert-*,cppcoreguidelines-*
  EXTERNAL_YAML_CLANG_TIDY_TIMEOUT_SEC=30
  EXTERNAL_YAML_BEARER_TIMEOUT_SEC=45
  EXTERNAL_CODEQL_DB=/abs/path/to/codeql_db
  EXTERNAL_CODEQL_QUERY_SUITE=codeql/cpp-queries:codeql-suites/cpp-security-and-quality.qls
  EXTERNAL_CODEQL_TIMEOUT_SEC=180
  EXTERNAL_CODEQL_CACHE_DIR=/tmp/pr-reviewer-codeql-cache
  EXTERNAL_CODEQL_CACHE_DISABLE=0
  DIFF_NATIVE_HEURISTICS=1
  DIFF_NATIVE_WINDOW=12
  DIFF_NATIVE_MAX_FINDINGS=12
  DIFF_NATIVE_STRICT=0
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

context_dir=""
repo_dir=""
base_ref=""
head_ref="HEAD"
checkpatch_cmd=""
style_family="auto"
fetch_checkpatch=1
checkpatch_inline_cap=0
comment_batch_size=50
cross_ecosystem_mode="repo-aware"
bug_model_path=""
bug_scorer_cmd=""
bug_binary_threshold="0.45"
bug_family_threshold="0.35"
bug_hunk_threshold="0.35"
bug_high_risk_fallback_threshold="0.90"
bug_guarded_risk_min_hunk="0.20"
bug_risk_only_fallback_threshold=""
bug_topk_hunks=5
ruleset_mode="all"
allow_scope_mismatch=0
output_file=""
report_file=""
include_clean=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context-dir)
      context_dir="${2:-}"
      shift 2
      ;;
    --repo-dir)
      repo_dir="${2:-}"
      shift 2
      ;;
    --base-ref)
      base_ref="${2:-}"
      shift 2
      ;;
    --head-ref)
      head_ref="${2:-}"
      shift 2
      ;;
    --checkpatch-cmd)
      checkpatch_cmd="${2:-}"
      shift 2
      ;;
    --style-family)
      style_family="${2:-}"
      shift 2
      ;;
    --checkpatch-inline-cap)
      checkpatch_inline_cap="${2:-0}"
      shift 2
      ;;
    --comment-batch-size)
      comment_batch_size="${2:-50}"
      shift 2
      ;;
    --cross-ecosystem-mode)
      cross_ecosystem_mode="${2:-repo-aware}"
      shift 2
      ;;
    --bug-model)
      bug_model_path="${2:-}"
      shift 2
      ;;
    --bug-scorer-cmd)
      bug_scorer_cmd="${2:-}"
      shift 2
      ;;
    --bug-binary-threshold)
      bug_binary_threshold="${2:-0.45}"
      shift 2
      ;;
    --bug-family-threshold)
      bug_family_threshold="${2:-0.35}"
      shift 2
      ;;
    --bug-hunk-threshold)
      bug_hunk_threshold="${2:-0.35}"
      shift 2
      ;;
    --bug-high-risk-fallback-threshold)
      bug_high_risk_fallback_threshold="${2:-0.90}"
      shift 2
      ;;
    --bug-guarded-risk-min-hunk)
      bug_guarded_risk_min_hunk="${2:-0.20}"
      shift 2
      ;;
    --bug-risk-only-fallback-threshold)
      bug_risk_only_fallback_threshold="${2:-}"
      shift 2
      ;;
    --bug-topk-hunks)
      bug_topk_hunks="${2:-5}"
      shift 2
      ;;
    --ruleset)
      ruleset_mode="${2:-all}"
      shift 2
      ;;
    --no-fetch-checkpatch)
      fetch_checkpatch=0
      shift
      ;;
    --allow-scope-mismatch)
      allow_scope_mismatch=1
      shift
      ;;
    --output)
      output_file="${2:-}"
      shift 2
      ;;
    --report-file)
      report_file="${2:-}"
      shift 2
      ;;
    --include-clean)
      include_clean=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

require_cmd jq
require_cmd awk
require_cmd sed
require_cmd git
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -n "$context_dir" ]] || err "--context-dir is required"
[[ -n "$repo_dir" ]] || err "--repo-dir is required"
[[ -d "$repo_dir/.git" ]] || err "Invalid --repo-dir (missing .git): $repo_dir"
case "$style_family" in
  auto|linux|qemu|uboot|edk2|generic) ;;
  *) err "Invalid --style-family: $style_family (use auto|linux|qemu|uboot|edk2|generic)" ;;
esac
[[ "$checkpatch_inline_cap" =~ ^[0-9]+$ ]] || err "Invalid --checkpatch-inline-cap: $checkpatch_inline_cap (use integer >= 0)"
[[ "$comment_batch_size" =~ ^[0-9]+$ ]] || err "Invalid --comment-batch-size: $comment_batch_size (use integer >= 1)"
[[ "$comment_batch_size" -ge 1 ]] || err "Invalid --comment-batch-size: $comment_batch_size (use integer >= 1)"
case "$cross_ecosystem_mode" in
  repo-aware|full) ;;
  *) err "Invalid --cross-ecosystem-mode: $cross_ecosystem_mode (use repo-aware|full)" ;;
esac
[[ "$bug_topk_hunks" =~ ^[0-9]+$ ]] || err "Invalid --bug-topk-hunks: $bug_topk_hunks (use integer >= 1)"
[[ "$bug_topk_hunks" -ge 1 ]] || err "Invalid --bug-topk-hunks: $bug_topk_hunks (use integer >= 1)"
[[ "$bug_binary_threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "Invalid --bug-binary-threshold: $bug_binary_threshold"
[[ "$bug_family_threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "Invalid --bug-family-threshold: $bug_family_threshold"
[[ "$bug_hunk_threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "Invalid --bug-hunk-threshold: $bug_hunk_threshold"
[[ "$bug_high_risk_fallback_threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "Invalid --bug-high-risk-fallback-threshold: $bug_high_risk_fallback_threshold"
[[ "$bug_guarded_risk_min_hunk" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "Invalid --bug-guarded-risk-min-hunk: $bug_guarded_risk_min_hunk"
if [[ -n "$bug_risk_only_fallback_threshold" ]]; then
  [[ "$bug_risk_only_fallback_threshold" =~ ^[0-9]+(\.[0-9]+)?$ ]] || err "Invalid --bug-risk-only-fallback-threshold: $bug_risk_only_fallback_threshold"
fi
case "$ruleset_mode" in
  all|repo-bug-model-rules) ;;
  *) err "Invalid --ruleset: $ruleset_mode (use all|repo-bug-model-rules)" ;;
esac

pr_json="$context_dir/pr.json"
files_json="$context_dir/files.json"
review_comments_json="$context_dir/review_comments.json"
issue_comments_json="$context_dir/issue_comments.json"
reviews_json="$context_dir/reviews.json"
commits_json="$context_dir/commits.json"
summary_txt="$context_dir/summary.txt"

[[ -f "$pr_json" ]] || err "Missing $pr_json"
[[ -f "$files_json" ]] || err "Missing $files_json"
[[ -f "$review_comments_json" ]] || err "Missing $review_comments_json"
[[ -f "$issue_comments_json" ]] || err "Missing $issue_comments_json"
[[ -f "$reviews_json" ]] || err "Missing $reviews_json"
[[ -f "$commits_json" ]] || err "Missing $commits_json"

owner="$(jq -r '.base.repo.owner.login // empty' "$pr_json")"
repo="$(jq -r '.base.repo.name // empty' "$pr_json")"
pr_number="$(jq -r '.number // empty' "$pr_json")"
pr_title="$(jq -r '.title // empty' "$pr_json")"
base_branch="$(jq -r '.base.ref // empty' "$pr_json")"
head_branch="$(jq -r '.head.ref // empty' "$pr_json")"
pr_url="$(jq -r '.html_url // empty' "$pr_json")"

normalize_remote_url() {
  local raw="$1"
  local host=""
  local path=""
  if [[ -z "$raw" ]]; then
    return 0
  fi
  if [[ "$raw" =~ ^git@([^:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^ssh://git@([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^https?://([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  else
    return 0
  fi
  path="${path%.git}"
  path="${path#/}"
  [[ -n "$host" && -n "$path" ]] || return 0
  printf 'https://%s/%s' "$host" "$path"
}

resolve_comment_repo_url() {
  local head_repo_html=""
  local head_repo_clone=""
  local base_repo_html=""
  local base_repo_clone=""
  local remote_url=""
  local normalized=""
  head_repo_html="$(jq -r '.head.repo.html_url // empty' "$pr_json" 2>/dev/null || true)"
  if [[ -n "$head_repo_html" ]]; then
    printf '%s' "$head_repo_html"
    return 0
  fi
  head_repo_clone="$(jq -r '.head.repo.clone_url // .head.repo.git_url // empty' "$pr_json" 2>/dev/null || true)"
  normalized="$(normalize_remote_url "$head_repo_clone" || true)"
  if [[ -n "$normalized" ]]; then
    printf '%s' "$normalized"
    return 0
  fi
  base_repo_html="$(jq -r '.base.repo.html_url // empty' "$pr_json" 2>/dev/null || true)"
  if [[ -n "$base_repo_html" ]]; then
    printf '%s' "$base_repo_html"
    return 0
  fi
  base_repo_clone="$(jq -r '.base.repo.clone_url // .base.repo.git_url // empty' "$pr_json" 2>/dev/null || true)"
  normalized="$(normalize_remote_url "$base_repo_clone" || true)"
  if [[ -n "$normalized" ]]; then
    printf '%s' "$normalized"
    return 0
  fi
  remote_url="$(git -C "$repo_dir" config --get remote.upstream.url || true)"
  if [[ -z "$remote_url" ]]; then
    remote_url="$(git -C "$repo_dir" config --get remote.origin.url || true)"
  fi
  normalized="$(normalize_remote_url "$remote_url" || true)"
  if [[ -z "$normalized" && -n "$owner" && -n "$repo" ]]; then
    normalized="https://github.com/${owner}/${repo}"
  fi
  printf '%s' "$normalized"
}

resolve_comment_head_sha() {
  local cand=""
  local resolved=""
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    [[ "$cand" =~ ^[0-9a-fA-F]{7,40}$ ]] || continue
    resolved="$(git -C "$repo_dir" rev-parse --verify "${cand}^{commit}" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      printf '%s' "$resolved"
      return 0
    fi
  done <<EOF
$(jq -r '.head.sha // empty' "$pr_json")
$(jq -r '._meta.head_sha // empty' "$pr_json")
$(jq -r '.[0].sha // empty' "$commits_json")
$(jq -r '.[-1].sha // empty' "$commits_json")
$head_ref
EOF
  return 0
}

urlencode_path() {
  local value="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$value" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe="/._-~"))
PY
  else
    printf '%s' "$value"
  fi
}

comment_repo_url="$(resolve_comment_repo_url)"
comment_head_sha="$(resolve_comment_head_sha)"

build_comment_permalink() {
  local file="$1"
  local line="$2"
  local file_enc=""
  [[ -n "$comment_repo_url" ]] || return 0
  [[ -n "$comment_head_sha" ]] || return 0
  [[ "$line" =~ ^[0-9]+$ ]] || return 0
  file_enc="$(urlencode_path "$file")"
  [[ -n "$file_enc" ]] || return 0
  printf '%s/blob/%s/%s#L%s' "$comment_repo_url" "$comment_head_sha" "$file_enc" "$line"
}

resolve_base_ref() {
  local root="$1"
  local base="$2"
  local cand=""

  if [[ -n "$base" ]]; then
    for cand in "upstream/${base}" "origin/${base}" "${base}"; do
      if git -C "$root" rev-parse --verify "$cand" >/dev/null 2>&1; then
        printf '%s' "$cand"
        return 0
      fi
    done
  fi

  for cand in "upstream/main" "upstream/master" "origin/main" "origin/master" "main" "master"; do
    if git -C "$root" rev-parse --verify "$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done

  return 1
}

if [[ -z "$base_ref" ]]; then
  base_ref="$(resolve_base_ref "$repo_dir" "$base_branch" || true)"
fi

[[ -n "$base_ref" ]] || err "Unable to resolve base ref. Pass --base-ref explicitly."

git -C "$repo_dir" rev-parse --verify "$base_ref" >/dev/null 2>&1 || err "Base ref not found: $base_ref"
git -C "$repo_dir" rev-parse --verify "$head_ref" >/dev/null 2>&1 || err "Head ref not found: $head_ref"

fetched_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
if [[ -f "$summary_txt" ]]; then
  maybe_fetch="$(awk -F= '/^fetched_at_utc=/{print $2}' "$summary_txt" || true)"
  [[ -n "$maybe_fetch" ]] && fetched_at="$maybe_fetch"
fi

files_count="$(jq 'length' "$files_json")"
review_comments_count="$(jq 'length' "$review_comments_json")"
issue_comments_count="$(jq 'length' "$issue_comments_json")"
reviews_count="$(jq 'length' "$reviews_json")"
commits_count="$(jq 'length' "$commits_json")"

total_additions="$(jq '[.[].additions // 0] | add // 0' "$files_json")"
total_deletions="$(jq '[.[].deletions // 0] | add // 0' "$files_json")"
pr_body="$(jq -r '.body // ""' "$pr_json")"
pr_draft="$(jq -r '.draft // false' "$pr_json")"
has_signedoff="$(jq -r 'any(.[]; (.commit.message // "" | test("Signed-off-by:")))' "$commits_json")"

tmp_dir="$(mktemp -d)"
report_md="$tmp_dir/review.md"
findings_md="$tmp_dir/findings.md"
files_rows_md="$tmp_dir/files_rows.md"
open_questions_md="$tmp_dir/open_questions.md"
external_notes_md="$tmp_dir/external_notes.md"
topic_tasks_md="$tmp_dir/topic_tasks.md"
rule_matrix_md="$tmp_dir/rule_matrix.md"
proposed_comments_md="$tmp_dir/proposed_comments.md"
proposed_comments_seen="$tmp_dir/proposed_comments.seen"
proposed_comments_tsv="$tmp_dir/proposed_comments.tsv"
model_comment_locations_txt="$tmp_dir/model_comment_locations.txt"
comment_filter_rejects_tsv="$tmp_dir/comment_filter_rejects.tsv"
added_line_keys_txt="$tmp_dir/added_line_keys.txt"
comment_batches_md="$tmp_dir/comment_batches.md"
checkpatch_log="$tmp_dir/checkpatch.log"
checkpatch_inline_raw_tsv="$tmp_dir/checkpatch_inline_raw.tsv"
clang_semantic_log="$tmp_dir/clang_semantic.log"
clang_semantic_raw_tsv="$tmp_dir/clang_semantic_raw.tsv"
changed_c_files_txt="$tmp_dir/changed_c_files.txt"
kernel_vuln_rules_json="$script_dir/../references/kernel_vuln_rules.json"
kernel_vuln_raw_tsv="$tmp_dir/kernel_vuln_raw.tsv"
kernel_vuln_log="$tmp_dir/kernel_vuln.log"
flawfinder_log="$tmp_dir/flawfinder.log"
flawfinder_raw_tsv="$tmp_dir/flawfinder_raw.tsv"
external_yaml_log="$tmp_dir/external_yaml.log"
external_yaml_raw_tsv="$tmp_dir/external_yaml_raw.tsv"
added_lines_tsv="$tmp_dir/added_lines.tsv"
deleted_lines_tsv="$tmp_dir/deleted_lines.tsv"
diff_native_checked_calls_tsv="$tmp_dir/diff_native_checked_calls.tsv"
pr_files_txt="$tmp_dir/pr_files.txt"
local_files_txt="$tmp_dir/local_files.txt"
bug_model_json="$tmp_dir/bug_model.json"
review_comments_md="$tmp_dir/review_comments.md"
trap 'rm -rf "$tmp_dir"' EXIT

: > "$findings_md"
: > "$files_rows_md"
: > "$open_questions_md"
: > "$external_notes_md"
: > "$topic_tasks_md"
: > "$rule_matrix_md"
: > "$proposed_comments_md"
: > "$proposed_comments_seen"
: > "$proposed_comments_tsv"
: > "$model_comment_locations_txt"
: > "$comment_filter_rejects_tsv"
: > "$added_line_keys_txt"
: > "$comment_batches_md"
: > "$checkpatch_log"
: > "$checkpatch_inline_raw_tsv"
: > "$clang_semantic_log"
: > "$clang_semantic_raw_tsv"
: > "$changed_c_files_txt"
: > "$kernel_vuln_raw_tsv"
: > "$kernel_vuln_log"
: > "$flawfinder_log"
: > "$flawfinder_raw_tsv"
: > "$external_yaml_log"
: > "$external_yaml_raw_tsv"
: > "$added_lines_tsv"
: > "$deleted_lines_tsv"
: > "$diff_native_checked_calls_tsv"
: > "$pr_files_txt"
: > "$local_files_txt"
: > "$bug_model_json"
: > "$review_comments_md"

kernel_vuln_rules_ran=0
kernel_vuln_findings_total=0
flawfinder_ran=0
flawfinder_findings_total=0
flawfinder_findings_pre_filter=0
flawfinder_findings_windowed=0
flawfinder_findings_deduped=0
flawfinder_findings_emitted=0
external_yaml_engine="${EXTERNAL_YAML_ENGINE:-off}"
external_yaml_engine="$(printf '%s' "$external_yaml_engine" | tr '[:upper:]' '[:lower:]')"
external_yaml_config="${EXTERNAL_YAML_CONFIG:-}"
if [[ -z "$external_yaml_config" && ( "$external_yaml_engine" == "semgrep" || "$external_yaml_engine" == "gitlab_sast" || "$external_yaml_engine" == "gitlab-sast" || "$external_yaml_engine" == "gitlab" || "$external_yaml_engine" == "gitlab_sast_passthrough" || "$external_yaml_engine" == "datadog" || "$external_yaml_engine" == "datadog_custom_rules" || "$external_yaml_engine" == "datadog-custom-rules" ) ]]; then
  external_yaml_config="$script_dir/../references/external_semgrep_c_secure.yml"
fi
external_yaml_config_display="$external_yaml_config"
declare -a external_yaml_config_list=()
IFS=',' read -r -a _external_yaml_cfg_parts <<< "$external_yaml_config"
for _cfg in "${_external_yaml_cfg_parts[@]}"; do
  _cfg_trimmed="$(printf '%s' "$_cfg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$_cfg_trimmed" ]] || continue
  external_yaml_config_list+=("$_cfg_trimmed")
done
if [[ "${#external_yaml_config_list[@]}" -eq 0 && ( "$external_yaml_engine" == "semgrep" || "$external_yaml_engine" == "gitlab_sast" || "$external_yaml_engine" == "gitlab-sast" || "$external_yaml_engine" == "gitlab" || "$external_yaml_engine" == "gitlab_sast_passthrough" || "$external_yaml_engine" == "datadog" || "$external_yaml_engine" == "datadog_custom_rules" || "$external_yaml_engine" == "datadog-custom-rules" ) ]]; then
  external_yaml_config_list=("$script_dir/../references/external_semgrep_c_secure.yml")
  external_yaml_config_display="${external_yaml_config_list[0]}"
elif [[ "${#external_yaml_config_list[@]}" -gt 0 ]]; then
  external_yaml_config_display="$(printf '%s' "${external_yaml_config_list[*]}" | tr ' ' ',')"
else
  external_yaml_config_display="(none)"
fi
external_yaml_window="${EXTERNAL_YAML_WINDOW:-3}"
if [[ ! "$external_yaml_window" =~ ^[0-9]+$ ]]; then
  external_yaml_window=3
fi
external_yaml_semgrep_scan_timeout_sec="${EXTERNAL_YAML_SEMGREP_SCAN_TIMEOUT_SEC:-45}"
if [[ ! "$external_yaml_semgrep_scan_timeout_sec" =~ ^[0-9]+$ ]]; then
  external_yaml_semgrep_scan_timeout_sec=45
fi
external_yaml_semgrep_rule_timeout_sec="${EXTERNAL_YAML_SEMGREP_RULE_TIMEOUT_SEC:-3}"
if [[ ! "$external_yaml_semgrep_rule_timeout_sec" =~ ^[0-9]+$ ]]; then
  external_yaml_semgrep_rule_timeout_sec=3
fi
external_yaml_semgrep_timeout_threshold="${EXTERNAL_YAML_SEMGREP_TIMEOUT_THRESHOLD:-1}"
if [[ ! "$external_yaml_semgrep_timeout_threshold" =~ ^[0-9]+$ ]]; then
  external_yaml_semgrep_timeout_threshold=1
fi
external_yaml_semgrep_max_target_bytes="${EXTERNAL_YAML_SEMGREP_MAX_TARGET_BYTES:-1000000}"
if [[ ! "$external_yaml_semgrep_max_target_bytes" =~ ^[0-9]+$ ]]; then
  external_yaml_semgrep_max_target_bytes=1000000
fi
external_yaml_semgrep_jobs="${EXTERNAL_YAML_SEMGREP_JOBS:-4}"
if [[ ! "$external_yaml_semgrep_jobs" =~ ^[0-9]+$ ]] || [[ "$external_yaml_semgrep_jobs" -lt 1 ]]; then
  external_yaml_semgrep_jobs=4
fi
external_yaml_clang_tidy_checks="${EXTERNAL_YAML_CLANG_TIDY_CHECKS:-clang-analyzer-*,cert-*,cppcoreguidelines-*}"
external_yaml_clang_tidy_timeout_sec="${EXTERNAL_YAML_CLANG_TIDY_TIMEOUT_SEC:-30}"
if [[ ! "$external_yaml_clang_tidy_timeout_sec" =~ ^[0-9]+$ ]] || [[ "$external_yaml_clang_tidy_timeout_sec" -lt 1 ]]; then
  external_yaml_clang_tidy_timeout_sec=30
fi
external_yaml_bearer_timeout_sec="${EXTERNAL_YAML_BEARER_TIMEOUT_SEC:-45}"
if [[ ! "$external_yaml_bearer_timeout_sec" =~ ^[0-9]+$ ]] || [[ "$external_yaml_bearer_timeout_sec" -lt 1 ]]; then
  external_yaml_bearer_timeout_sec=45
fi
external_yaml_gitlab_ruleset="${EXTERNAL_GITLAB_SAST_RULESET:-}"
external_yaml_datadog_rules="${EXTERNAL_DATADOG_RULES:-}"
external_yaml_codeql_db="${EXTERNAL_CODEQL_DB:-}"
external_yaml_codeql_query_suite="${EXTERNAL_CODEQL_QUERY_SUITE:-codeql/cpp-queries:codeql-suites/cpp-security-and-quality.qls}"
external_yaml_codeql_timeout_sec="${EXTERNAL_CODEQL_TIMEOUT_SEC:-180}"
if [[ ! "$external_yaml_codeql_timeout_sec" =~ ^[0-9]+$ ]] || [[ "$external_yaml_codeql_timeout_sec" -lt 1 ]]; then
  external_yaml_codeql_timeout_sec=180
fi
external_yaml_codeql_cache_dir="${EXTERNAL_CODEQL_CACHE_DIR:-/tmp/pr-reviewer-codeql-cache}"
external_yaml_codeql_cache_disable="${EXTERNAL_CODEQL_CACHE_DISABLE:-0}"
if [[ "$external_yaml_codeql_cache_disable" != "0" && "$external_yaml_codeql_cache_disable" != "1" ]]; then
  external_yaml_codeql_cache_disable=0
fi
diff_native_heuristics="${DIFF_NATIVE_HEURISTICS:-0}"
if [[ "$diff_native_heuristics" != "0" && "$diff_native_heuristics" != "1" ]]; then
  diff_native_heuristics=0
fi
diff_native_window="${DIFF_NATIVE_WINDOW:-12}"
if [[ ! "$diff_native_window" =~ ^[0-9]+$ ]]; then
  diff_native_window=12
fi
diff_native_max_findings="${DIFF_NATIVE_MAX_FINDINGS:-12}"
if [[ ! "$diff_native_max_findings" =~ ^[0-9]+$ ]] || [[ "$diff_native_max_findings" -lt 1 ]]; then
  diff_native_max_findings=12
fi
diff_native_strict="${DIFF_NATIVE_STRICT:-0}"
if [[ "$diff_native_strict" != "0" && "$diff_native_strict" != "1" ]]; then
  diff_native_strict=0
fi
external_yaml_ran=0
external_yaml_findings_total=0
external_yaml_findings_pre_filter=0
external_yaml_findings_windowed=0
external_yaml_findings_deduped=0
external_yaml_findings_emitted=0
bug_model_ran=0
bug_model_status="not-run"
bug_model_review_mode=""
bug_model_risk_score="0.0"
bug_model_family=""
bug_model_family_score="0.0"
bug_model_best_hunk_score="0.0"
bug_model_hunk_file=""
bug_model_hunk_line=""
bug_model_memory_used="false"
bug_model_source="unset"
bug_model_fallback_injected=0
bug_model_risk_fallback_injected=0

# Build changed file rows.
jq -r '.[] | [(.filename // ""), (.status // ""), ((.additions // 0)|tostring), ((.deletions // 0)|tostring)] | @tsv' "$files_json" | \
while IFS=$'\t' read -r f s a d; do
  [[ -z "$f" ]] && continue
  printf '| `%s` | `%s` | `%s` | `%s` |\n' "$f" "$s" "$a" "$d" >> "$files_rows_md"
done

# Enforce local diff scope to match fetched PR files.
jq -r '.[].filename // empty' "$files_json" | sed '/^$/d' | sort -u > "$pr_files_txt"
git -C "$repo_dir" diff --name-only "$base_ref...$head_ref" | sed '/^$/d' | sort -u > "$local_files_txt"
if ! diff -u "$pr_files_txt" "$local_files_txt" >/dev/null 2>&1; then
  if [[ "$allow_scope_mismatch" -eq 0 ]]; then
    echo "Expected PR files (GitHub):" >&2
    sed -n '1,80p' "$pr_files_txt" >&2
    echo "Local files (${base_ref}...${head_ref}):" >&2
    sed -n '1,80p' "$local_files_txt" >&2
    err "Local diff scope does not match fetched PR scope. Check out the correct PR branch/head or pass --allow-scope-mismatch."
  fi
fi

# Parse added patch lines with file+line locations for autonomous review heuristics.
git -C "$repo_dir" diff -U0 "$base_ref...$head_ref" | \
awk '
BEGIN { file=""; line=0; in_hunk=0; OFS="\t" }
/^diff --git / {
  in_hunk=0
  file=$4
  sub(/^b\//, "", file)
  next
}
/^@@ / {
  in_hunk=1
  if (match($0, /\+([0-9]+)/, m)) {
    line=m[1]
  } else {
    line=0
  }
  next
}
in_hunk && /^\+\+\+/ { next }
in_hunk && /^\+/ {
  txt=substr($0,2)
  print file, line, txt
  line++
  next
}
in_hunk && /^-/ { next }
in_hunk {
  line++
}
' > "$added_lines_tsv"

# Parse deleted patch lines (old-file line numbers) for diff-native heuristics.
git -C "$repo_dir" diff -U0 "$base_ref...$head_ref" | \
awk '
BEGIN { file=""; line=0; in_hunk=0; OFS="\t" }
/^diff --git / {
  in_hunk=0
  file=$4
  sub(/^b\//, "", file)
  next
}
/^@@ / {
  in_hunk=1
  if (match($0, /-([0-9]+)/, m)) {
    line=m[1]
  } else {
    line=0
  }
  next
}
in_hunk && /^\+\+\+/ { next }
in_hunk && /^---/ { next }
in_hunk && /^-/ {
  txt=substr($0,2)
  print file, line, txt
  line++
  next
}
in_hunk && /^\+/ { next }
in_hunk {
  line++
}
' > "$deleted_lines_tsv"

awk -F'\t' 'NF >= 2 && $1 != "" && $2 ~ /^[0-9]+$/ {print $1 ":" $2}' "$added_lines_tsv" | sort -u > "$added_line_keys_txt"

finding_id=0
comment_reanchored_total=0
add_finding() {
  local severity="$1"
  local category="$2"
  local location="$3"
  local evidence="$4"
  local risk="$5"
  local action="$6"
  local rule_id="${7:-}"
  local rule_link="${8:-}"
  finding_id=$((finding_id + 1))
  {
    echo "### F${finding_id} - ${severity^^} - ${category}"
    echo "- Location: ${location}"
    echo "- Evidence: ${evidence}"
    echo "- Risk: ${risk}"
    echo "- Recommended action: ${action}"
    echo
  } >> "$findings_md"

  maybe_add_proposed_comment "$severity" "$category" "$location" "$evidence" "$action" "$rule_id" "$rule_link" || true
}

is_code_file_for_review_comment() {
  local file="$1"
  case "$file" in
    *.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.hh|*.m|*.mm|*.S|*.s|*.asm|*.py|*.go|*.rs|*.java|*.js|*.ts|*.tsx|*.php|*.rb|*.pl|*.sh|*.asl|*.mk|*.dts|*.dtsi|Doxyfile|*/Doxyfile)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_non_actionable_source_line() {
  local src="$1"
  local trimmed=""
  trimmed="$(printf '%s' "$src" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$trimmed" ]] || return 0
  printf '%s\n' "$trimmed" | grep -Eq '^#include[[:space:]]*<' && return 0
  printf '%s\n' "$trimmed" | grep -Eq '^(//|/\*|\*|///)' && return 0
  printf '%s\n' "$trimmed" | grep -Eq '^from:[[:space:]]' && return 0
  printf '%s\n' "$trimmed" | grep -Eq '^#!/' && return 0
  printf '%s\n' "$trimmed" | grep -Eq '^-?[[:space:]]+[[:alnum:]_./-]+\.(inf|dec|dsc|md|yaml|yml|json|toml|ini)$' && return 0
  printf '%s\n' "$trimmed" | grep -Eq '^[[:alnum:]_./-]+\.(inf|dec|dsc|md|yaml|yml|json|toml|ini)$' && return 0
  return 1
}

line_has_div_or_mod_expr() {
  local src="$1"
  printf '%s\n' "$src" | grep -Eq '[[:alnum:]_)\]]+[[:space:]]*/[[:space:]]*[[:alnum:]_(]+' && return 0
  printf '%s\n' "$src" | grep -Eq '[[:alnum:]_)\]]+[[:space:]]%[[:space:]]*[[:alnum:]_(]+' && return 0
  return 1
}

line_has_pointer_deref() {
  local src="$1"
  printf '%s\n' "$src" | grep -Eq -- '->|\\*[[:space:]]*[[:alnum:]_]|&[[:space:]]*[[:alnum:]_][[:alnum:]_]*->|\b(IS_ERR|IS_ERR_OR_NULL|PTR_ERR|WARN_ON|BUG_ON)[[:space:]]*\(|![[:space:]]*[[:alnum:]_][[:alnum:]_]*\b' && return 0
  return 1
}

line_has_bounds_tokens() {
  local src="$1"
  printf '%s\n' "$src" | grep -Eiq '\[(.+)\]|\b(index|idx|len|length|size|count|offset|array|buffer|mask|policy|range|limit|end|start)\b|ARRAY_SIZE[[:space:]]*\(|sizeof[[:space:]]*\(|strnlen[[:space:]]*\(|WARN_ON[[:space:]]*\(|>=|<=|<|>|~[[:space:]]*[[:alnum:]_(]' && return 0
  return 1
}

line_has_sync_tokens() {
  local src="$1"
  printf '%s\n' "$src" | grep -Eiq '\b(lock|unlock|mutex|spin|rwsem|semaphore|rcu|atomic|barrier|READ_ONCE|WRITE_ONCE|lockless|timer|work|queue|irq|preempt|wakeup|wait|completion|flush|cancel|stop|race|deadlock)\b' && return 0
  return 1
}

float_ge() {
  local lhs="$1"
  local rhs="$2"
  awk -v a="$lhs" -v b="$rhs" 'BEGIN { exit ((a + 0.0) >= (b + 0.0) ? 0 : 1) }'
}

comment_gate_reason=""
comment_gate_resolved_line=""
comment_gate_reanchor_note=""

list_candidate_changed_lines() {
  local file="$1"
  local line="$2"
  local window="$3"
  awk -F'\t' -v f="$file" -v l="$line" -v w="$window" '
($1 == f && $2 ~ /^[0-9]+$/) {
  d = $2 - l
  if (d < 0) d = -d
  if (w < 0 || d <= w) print d "\t" $2
}
' "$added_lines_tsv" | sort -n -k1,1 -k2,2n | awk -F'\t' '!seen[$2]++ {print $2}'
}

line_passes_rule_specific_gates() {
  local file="$1"
  local cand_line="$2"
  local source_line="$3"
  local evidence="$4"
  local rule_id="$5"
  local lower=""
  local ml_delta=0

  lower="$(printf '%s %s' "$evidence" "$rule_id" | tr '[:upper:]' '[:lower:]')"

  if [[ "$rule_id" == "ML-PAIRWISE-DETECTOR" || "$rule_id" == "REPO-BUG-MODEL-RULE-1" ]]; then
    if [[ -n "$bug_model_hunk_file" && "$bug_model_hunk_line" =~ ^[0-9]+$ ]]; then
      if [[ "$file" != "$bug_model_hunk_file" ]]; then
        comment_gate_reason="ml-location-mismatch"
        return 1
      fi
      ml_delta=$((cand_line - bug_model_hunk_line))
      if [[ "$ml_delta" -lt 0 ]]; then
        ml_delta=$(( -ml_delta ))
      fi
      if [[ "$ml_delta" -gt 8 ]]; then
        if [[ "$ml_delta" -gt 30 ]]; then
          comment_gate_reason="ml-location-mismatch"
          return 1
        fi
      fi
    fi
    return 0
  fi

  if [[ "$lower" == *"divide/modulo"* || "$lower" == *"divide-by-zero"* || "$rule_id" == "KV-DIVIDE-BY-ZERO-1" ]]; then
    if ! line_has_div_or_mod_expr "$source_line"; then
      comment_gate_reason="no-divmod-expression"
      return 1
    fi
  fi

  if [[ "$lower" == *"unchecked return-value candidate"* ]]; then
    case "$file" in
      *.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.hh) ;;
      *)
        comment_gate_reason="unchecked-return-non-c-family"
        return 1
        ;;
    esac
  fi

  if [[ "$lower" == *"hardcoded secret/credential"* ]]; then
    if ! printf '%s\n' "$source_line" | grep -Eqi '(AKIA[0-9A-Z]{16}|BEGIN[[:space:]]+PRIVATE[[:space:]]+KEY|password[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{6,}|passwd[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{6,}|api[_-]?key[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{6,}|secret[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{6,}|token[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{10,})'; then
      comment_gate_reason="no-secret-literal-evidence"
      return 1
    fi
  fi

  if [[ "$lower" == *"null-deref"* || "$lower" == *"dereference"* || "$rule_id" == "KV-NULL-DEREF-1" ]]; then
    if ! line_has_pointer_deref "$source_line"; then
      comment_gate_reason="no-dereference-expression"
      return 1
    fi
  fi

  if [[ "$lower" == *"out-of-bounds"* || "$lower" == *"index/length"* || "$lower" == *"invalid memory access"* ]]; then
    if ! line_has_bounds_tokens "$source_line"; then
      comment_gate_reason="no-bounds-expression"
      return 1
    fi
  fi

  return 0
}

comment_passes_precision_gates() {
  local file="$1"
  local line="$2"
  local evidence="$3"
  local rule_id="$4"
  local source_line=""
  local lower=""
  local key=""
  local candidates=""
  local cand=""

  comment_gate_reason=""
  comment_gate_resolved_line=""
  comment_gate_reanchor_note=""
  key="${file}:${line}"

  if ! is_code_file_for_review_comment "$file"; then
    if [[ "$rule_id" == "ML-PAIRWISE-DETECTOR" || "$rule_id" == "REPO-BUG-MODEL-RULE-1" ]]; then
      if [[ "${bug_model_review_mode:-}" == "actual-bug" || "${bug_model_review_mode:-}" == "actual-bug-lite" ]] && float_ge "${bug_model_risk_score:-0}" "$bug_high_risk_fallback_threshold"; then
        comment_gate_resolved_line="$line"
        return 0
      fi
    fi
    comment_gate_reason="non-code-file"
    return 1
  fi

  lower="$(printf '%s %s' "$evidence" "$rule_id" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"confidence=low"* ]]; then
    comment_gate_reason="low-confidence-signal"
    return 1
  fi

  # Static-analysis findings: use the exact reported line without re-anchoring.
  # Require strict proximity to changed lines to keep findings actionable.
  if [[ "$rule_id" == FF-* || "$rule_id" == SG-* ]]; then
    local static_window=3
    if [[ "$rule_id" == SG-* ]]; then
      static_window="$external_yaml_window"
    fi
    source_line="$(source_line_for_location "$file" "$line")"
    if ! is_non_actionable_source_line "$source_line"; then
      nearest="$(list_candidate_changed_lines "$file" "$line" "$static_window" || true)"
      if [[ -n "$nearest" ]]; then
        comment_gate_resolved_line="$line"
        return 0
      fi
    fi
    comment_gate_reason="not-on-changed-line"
    return 1
  fi

  if grep -Fqx "$key" "$added_line_keys_txt"; then
    candidates="$line"
    candidates="$(printf '%s\n%s\n%s\n' "$candidates" "$(list_candidate_changed_lines "$file" "$line" 5 || true)" "$(list_candidate_changed_lines "$file" "$line" 20 || true)" | sed '/^$/d' | awk '!seen[$0]++')"
  else
    candidates="$(list_candidate_changed_lines "$file" "$line" 5 || true)"
    if [[ -z "$candidates" ]]; then
      candidates="$(list_candidate_changed_lines "$file" "$line" 20 || true)"
    fi
    if [[ -z "$candidates" ]]; then
      comment_gate_reason="not-on-changed-line"
      return 1
    fi
  fi

  while IFS= read -r cand; do
    [[ "$cand" =~ ^[0-9]+$ ]] || continue
    source_line="$(source_line_for_location "$file" "$cand")"
    if is_non_actionable_source_line "$source_line"; then
      if [[ "$rule_id" == "ML-PAIRWISE-DETECTOR" || "$rule_id" == "REPO-BUG-MODEL-RULE-1" ]] && [[ "${bug_model_family:-}" == "unknown" ]]; then
        case "$file" in
          *.mk|*.dts|*.dtsi|Doxyfile|*/Doxyfile)
            comment_gate_resolved_line="$cand"
            if [[ "$cand" != "$line" ]]; then
              comment_gate_reanchor_note="auto-relocated from ${file}:${line} to ${file}:${cand}"
            fi
            return 0
            ;;
        esac
      fi
      comment_gate_reason="non-actionable-source-line"
      continue
    fi
    if line_passes_rule_specific_gates "$file" "$cand" "$source_line" "$evidence" "$rule_id"; then
      comment_gate_resolved_line="$cand"
      if [[ "$cand" != "$line" ]]; then
        comment_gate_reanchor_note="auto-relocated from ${file}:${line} to ${file}:${cand}"
      fi
      return 0
    fi
  done <<< "$candidates"

  return 1
}

maybe_add_proposed_comment() {
  local severity="$1"
  local category="$2"
  local location="$3"
  local evidence="$4"
  local action="$5"
  local rule_id="${6:-}"
  local rule_link="${7:-}"
  local file=""
  local line=""
  local key=""
  local key_evidence=""
  local msg=""
  local preferred_msg=""
  local original_line=""

  case "$severity" in
    high|medium) ;;
    *) return 1 ;;
  esac

  if [[ ! "$location" =~ ^([^:]+):([0-9]+)$ ]]; then
    return 1
  fi
  file="${BASH_REMATCH[1]}"
  line="${BASH_REMATCH[2]}"
  [[ -n "$file" && -n "$line" ]] || return 1
  original_line="$line"

  if ! comment_passes_precision_gates "$file" "$line" "$evidence" "$rule_id"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$severity" "$file" "$line" "$rule_id" "$comment_gate_reason" "$evidence" >> "$comment_filter_rejects_tsv"
    return 1
  fi
  if [[ -n "$comment_gate_resolved_line" ]]; then
    line="$comment_gate_resolved_line"
    if [[ "$line" != "$original_line" ]]; then
      comment_reanchored_total=$((comment_reanchored_total + 1))
    fi
  fi

  key_evidence="$(printf '%s' "$evidence" | sed 's/[[:space:]]\+/ /g')"
  key="${file}:${line}|${category}|${key_evidence}|${rule_id}|${rule_link}"
  if grep -Fqx "$key" "$proposed_comments_seen"; then
    return 1
  fi
  echo "$key" >> "$proposed_comments_seen"
  if [[ "$rule_id" == "REPO-BUG-MODEL-RULE-1" || "$rule_id" == "ML-PAIRWISE-DETECTOR" ]]; then
    echo "${file}:${line}" >> "$model_comment_locations_txt"
  fi

  if [[ "$rule_id" == "REPO-BUG-MODEL-RULE-1" || "$rule_id" == "ML-PAIRWISE-DETECTOR" ]]; then
    preferred_msg="$(build_model_precise_comment "$file" "$line" "$evidence" "$action" || true)"
  fi

  if [[ -n "$preferred_msg" ]]; then
    msg="$preferred_msg"
  else
    msg="Potential ${category} issue: ${evidence} Recommended: ${action}"
  fi
  if [[ -n "$rule_id" ]]; then
    msg="${msg} Rule: ${rule_id}."
  fi
  if [[ -n "$rule_link" ]]; then
    msg="${msg} Source: ${rule_link}."
  fi
  if [[ -n "$comment_gate_reanchor_note" ]]; then
    msg="${msg} Location note: ${comment_gate_reanchor_note}."
  fi
  msg="$(printf '%s' "$msg" | sed 's/[[:space:]]\+/ /g' | sed 's/`//g')"
  {
    echo "- [ ] ${severity^^} | ${file}:${line}"
    echo "  - Draft comment: ${msg}"
  } >> "$proposed_comments_md"
  printf '%s\t%s\t%s\t%s\n' "$severity" "$file" "$line" "$msg" >> "$proposed_comments_tsv"
  return 0
}

detect_model_family() {
  local evidence="$1"
  local family=""
  family="${bug_model_family:-}"
  if [[ -z "$family" ]]; then
    family="$(printf '%s' "$evidence" | sed -nE 's/.*predicts ([a-z0-9-]+).*/\1/p' | head -n1 || true)"
  fi
  printf '%s' "$family"
}

source_line_for_location() {
  local file="$1"
  local line="$2"
  local text=""
  [[ "$line" =~ ^[0-9]+$ ]] || return 0
  text="$(git -C "$repo_dir" show "${head_ref}:${file}" 2>/dev/null | sed -n "${line}p" || true)"
  text="$(printf '%s' "$text" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\+/ /g')"
  printf '%s' "$text"
}

model_cause_hint() {
  local family="$1"
  local source_line="$2"
  case "$family" in
    memory-leak)
      if [[ "$source_line" =~ (g_new0|g_malloc|malloc|calloc|realloc|new[[:space:]]*\() ]]; then
        printf '%s' "unconditional allocation on a repeated path can overwrite existing state and leak previous allocation"
      else
        printf '%s' "allocation/ownership lifecycle is inconsistent and can leak heap state across repeated execution paths"
      fi
      ;;
    out-of-bounds|buffer-overflow|off-by-one)
      printf '%s' "bounds for index/length are not strongly guaranteed on this code path, which can permit invalid memory access"
      ;;
    null-deref)
      if [[ "$source_line" == *"->"* ]]; then
        printf '%s' "pointer dereference is reached without a guaranteed non-NULL object on all paths"
      else
        printf '%s' "code path can operate on an uninitialized/NULL object"
      fi
      ;;
    use-after-free)
      printf '%s' "object lifetime/ownership can allow access after release on this path"
      ;;
    race-condition|deadlock)
      printf '%s' "shared state transitions on this path can race without a single synchronization boundary"
      ;;
    integer-overflow|divide-by-zero)
      printf '%s' "arithmetic safety checks are insufficient for all runtime inputs on this path"
      ;;
    double-free|refcount)
      printf '%s' "resource lifetime accounting can become inconsistent, leading to invalid free/use paths"
      ;;
    uninitialized)
      printf '%s' "state can be consumed before guaranteed initialization on this path"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

model_fix_hint() {
  local family="$1"
  local action="$2"
  case "$family" in
    memory-leak)
      printf '%s' "guard one-time allocation/ownership (for example allocate only when pointer is NULL), and add explicit cleanup on all error/teardown paths"
      ;;
    out-of-bounds|buffer-overflow|off-by-one)
      printf '%s' "add strict bounds checks before access and fail fast when index/length is outside valid range"
      ;;
    null-deref)
      printf '%s' "add explicit NULL/stub validation before dereference and return a handled error when object state is invalid"
      ;;
    use-after-free)
      printf '%s' "reorder lifetime so accesses happen before release and clear/re-own pointers after free"
      ;;
    race-condition|deadlock)
      printf '%s' "protect this state transition with consistent locking/atomic discipline so checks and updates happen under one synchronization rule"
      ;;
    integer-overflow|divide-by-zero)
      printf '%s' "validate arithmetic operands before operation and clamp/reject invalid values"
      ;;
    double-free|refcount)
      printf '%s' "enforce single-owner release semantics and validate refcount transitions before free"
      ;;
    uninitialized)
      printf '%s' "initialize state before first use and add guards for partial-init paths"
      ;;
    *)
      if [[ -n "$action" ]]; then
        printf '%s' "$action"
      else
        printf '%s' ""
      fi
      ;;
  esac
}

build_model_precise_comment() {
  local file="$1"
  local line="$2"
  local evidence="$3"
  local action="$4"
  local family=""
  local source_line=""
  local cause=""
  local fix=""

  family="$(detect_model_family "$evidence")"
  source_line="$(source_line_for_location "$file" "$line")"
  cause="$(model_cause_hint "$family" "$source_line")"
  fix="$(model_fix_hint "$family" "$action")"

  if [[ -z "$cause" || -z "$fix" ]]; then
    return 1
  fi

  if [[ -n "$source_line" ]]; then
    if [[ "${#source_line}" -gt 180 ]]; then
      source_line="${source_line:0:177}..."
    fi
    printf '%s' "Specific cause: ${cause}. Path: ${file}:${line} (line: ${source_line}). Fix: ${fix}."
  else
    printf '%s' "Specific cause: ${cause}. Path: ${file}:${line}. Fix: ${fix}."
  fi
  return 0
}

strip_optional_quotes() {
  local value="$1"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

repo_model_env_suffix() {
  local repo_name=""
  repo_name="$(basename "${repo_dir:-}")"
  repo_name="$(printf '%s' "$repo_name" | tr '[:lower:].-' '[:upper:]__' | tr -cd 'A-Z0-9_')"
  printf '%s' "$repo_name"
}

load_bug_model_from_env_file() {
  local env_file="$1"
  local env_model=""
  local env_scorer=""
  local repo_suffix=""
  [[ -f "$env_file" ]] || return 1

  repo_suffix="$(repo_model_env_suffix)"
  if [[ -n "$repo_suffix" ]]; then
    env_model="$(sed -n "s/^BUG_MODEL_PATH_${repo_suffix}=//p" "$env_file" | head -n1 || true)"
    env_scorer="$(sed -n "s/^BUG_SCORER_CMD_${repo_suffix}=//p" "$env_file" | head -n1 || true)"
  fi
  if [[ -z "$env_model" ]]; then
    env_model="$(sed -n 's/^BUG_MODEL_PATH=//p' "$env_file" | head -n1 || true)"
  fi
  if [[ -z "$env_scorer" ]]; then
    env_scorer="$(sed -n 's/^BUG_SCORER_CMD=//p' "$env_file" | head -n1 || true)"
  fi
  env_model="$(strip_optional_quotes "$env_model")"
  env_scorer="$(strip_optional_quotes "$env_scorer")"

  if [[ -n "$env_model" && -f "$env_model" ]]; then
    bug_model_path="$env_model"
    if [[ -z "$bug_scorer_cmd" && -n "$env_scorer" ]]; then
      bug_scorer_cmd="$env_scorer"
    fi
    bug_model_source="config:${env_file}"
    return 0
  fi
  return 1
}

resolve_model_from_bundle_dir() {
  local bundle_dir="$1"
  local candidate=""
  [[ -d "$bundle_dir/models" ]] || return 1

  for candidate in "$bundle_dir"/models/bug_risk_pairwise*.joblib "$bundle_dir"/models/*.joblib; do
    [[ -f "$candidate" ]] || continue
    bug_model_path="$candidate"
    if [[ -z "$bug_scorer_cmd" && -x "$bundle_dir/runtime/install.sh" ]]; then
      bug_scorer_cmd="$bundle_dir/runtime/install.sh --score-pairwise"
    fi
    bug_model_source="bundle:${bundle_dir}"
    return 0
  done

  return 1
}

resolve_bug_model_defaults() {
  local env_file=""
  local root=""
  local bundle_dir=""
  local repo_suffix=""
  local env_repo_model_key=""
  local env_repo_scorer_key=""

  if [[ -n "$bug_model_path" ]]; then
    if [[ -f "$bug_model_path" ]]; then
      if [[ "$bug_model_source" == "unset" || "$bug_model_source" == "not-found" || "$bug_model_source" == "cli-missing" ]]; then
        bug_model_source="cli"
      fi
      return 0
    fi
    bug_model_source="cli-missing"
    return 1
  fi

  repo_suffix="$(repo_model_env_suffix)"
  if [[ -n "$repo_suffix" ]]; then
    env_repo_model_key="BUG_MODEL_PATH_${repo_suffix}"
    env_repo_scorer_key="BUG_SCORER_CMD_${repo_suffix}"
    if [[ -n "${!env_repo_model_key:-}" && -f "${!env_repo_model_key}" ]]; then
      bug_model_path="${!env_repo_model_key}"
      if [[ -z "$bug_scorer_cmd" && -n "${!env_repo_scorer_key:-}" ]]; then
        bug_scorer_cmd="${!env_repo_scorer_key}"
      fi
      bug_model_source="env:${env_repo_model_key}"
      return 0
    fi
  fi

  if [[ -n "${BUG_MODEL_PATH:-}" && -f "${BUG_MODEL_PATH}" ]]; then
    bug_model_path="${BUG_MODEL_PATH}"
    if [[ -z "$bug_scorer_cmd" && -n "${BUG_SCORER_CMD:-}" ]]; then
      bug_scorer_cmd="${BUG_SCORER_CMD}"
    fi
    bug_model_source="env:BUG_MODEL_PATH"
    return 0
  fi

  for env_file in \
    "$HOME/.config/pr-reviewer-skill/bug-model.env" \
    "/local/mnt/workspace/.config/pr-reviewer-skill/bug-model.env"
  do
    if load_bug_model_from_env_file "$env_file"; then
      return 0
    fi
  done

  for root in \
    "/local/mnt/workspace/git/ml-bug-feature-models" \
    "$HOME/git/ml-bug-feature-models"
  do
    [[ -d "$root" ]] || continue

    if [[ -L "$root/current" || -d "$root/current" ]]; then
      bundle_dir="$(realpath "$root/current" 2>/dev/null || true)"
      if [[ -n "$bundle_dir" ]] && resolve_model_from_bundle_dir "$bundle_dir"; then
        return 0
      fi
    fi

    bundle_dir="$(find "$root" -maxdepth 2 -type f -name MODEL_INFO.json -printf '%h\n' 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$bundle_dir" ]] && resolve_model_from_bundle_dir "$bundle_dir"; then
      return 0
    fi
  done

  bug_model_source="not-found"
  return 1
}

resolve_bug_scorer_cmd() {
  local model_dir=""
  local bundle_dir=""

  if [[ -n "$bug_scorer_cmd" ]]; then
    printf '%s' "$bug_scorer_cmd"
    return 0
  fi

  if [[ -n "$bug_model_path" && -f "$bug_model_path" ]]; then
    model_dir="$(dirname "$bug_model_path")"
    bundle_dir="$(dirname "$model_dir")"
    if [[ -x "$bundle_dir/runtime/install.sh" ]]; then
      printf '%s' "$bundle_dir/runtime/install.sh --score-pairwise"
      return 0
    fi
  fi

  if [[ -n "${BUG_SCORER_CMD:-}" ]]; then
    printf '%s' "${BUG_SCORER_CMD}"
    return 0
  fi

  if [[ -x "/local/mnt/workspace/git/ml-bug-feature-extractor/install.sh" ]]; then
    printf '%s' "/local/mnt/workspace/git/ml-bug-feature-extractor/install.sh --score-pairwise"
    return 0
  fi

  if [[ -x "$HOME/git/ml-bug-feature-extractor/install.sh" ]]; then
    printf '%s' "$HOME/git/ml-bug-feature-extractor/install.sh --score-pairwise"
    return 0
  fi

  return 1
}

inject_high_risk_model_fallback_comment() {
  local file=""
  local line=""
  local key=""
  local msg=""

  bug_model_fallback_injected=0
  [[ -s "$proposed_comments_tsv" ]] && return 0
  [[ "$bug_model_status" == "ok" ]] || return 0
  [[ "$bug_model_review_mode" == "actual-bug" || "$bug_model_review_mode" == "actual-bug-lite" ]] || return 0
  if ! float_ge "${bug_model_risk_score:-0}" "$bug_high_risk_fallback_threshold"; then
    return 0
  fi

  file="${bug_model_hunk_file:-model-scorer}"
  line="${bug_model_hunk_line:-1}"
  [[ "$line" =~ ^[0-9]+$ ]] || line=1
  key="${file}:${line}|correctness|high-risk-model-fallback|ML-PAIRWISE-FALLBACK|https://github.com/slingappa/ml-bug-feature-extractor"
  if grep -Fqx "$key" "$proposed_comments_seen"; then
    return 0
  fi
  echo "$key" >> "$proposed_comments_seen"
  echo "${file}:${line}" >> "$model_comment_locations_txt"
  msg="High-risk model alert: actual-bug mode with risk=${bug_model_risk_score}. Line-level candidates were filtered; perform targeted manual validation on ${file}:${line} before approval. Rule: ML-PAIRWISE-FALLBACK. Source: https://github.com/slingappa/ml-bug-feature-extractor."
  {
    echo "- [ ] HIGH | ${file}:${line}"
    echo "  - Draft comment: ${msg}"
  } >> "$proposed_comments_md"
  printf '%s\t%s\t%s\t%s\n' "high" "$file" "$line" "$msg" >> "$proposed_comments_tsv"
  bug_model_fallback_injected=1
}

inject_risk_only_model_fallback_comment() {
  local file=""
  local line=""
  local key=""
  local msg=""

  bug_model_risk_fallback_injected=0
  [[ -n "$bug_risk_only_fallback_threshold" ]] || return 0
  [[ -s "$proposed_comments_tsv" ]] && return 0
  [[ "$bug_model_status" == "ok" ]] || return 0
  [[ "$bug_model_review_mode" == "risk-only" ]] || return 0
  if ! float_ge "${bug_model_risk_score:-0}" "$bug_risk_only_fallback_threshold"; then
    return 0
  fi
  if ! float_ge "${bug_model_best_hunk_score:-0}" "$bug_guarded_risk_min_hunk"; then
    return 0
  fi

  file="${bug_model_hunk_file:-model-scorer}"
  line="${bug_model_hunk_line:-1}"
  [[ "$line" =~ ^[0-9]+$ ]] || line=1
  key="${file}:${line}|correctness|risk-only-model-fallback|ML-PAIRWISE-RISK-FALLBACK|https://github.com/slingappa/ml-bug-feature-extractor"
  if grep -Fqx "$key" "$proposed_comments_seen"; then
    return 0
  fi
  echo "$key" >> "$proposed_comments_seen"
  if [[ "$file" != "model-scorer" ]]; then
    echo "${file}:${line}" >> "$model_comment_locations_txt"
  fi
  msg="Model risk-only fallback: risk=${bug_model_risk_score}, top_hunk=${bug_model_best_hunk_score}. No line-level comments survived precision gates; run targeted manual validation at ${file}:${line} before approval. Rule: ML-PAIRWISE-RISK-FALLBACK. Source: https://github.com/slingappa/ml-bug-feature-extractor."
  {
    echo "- [ ] MEDIUM | ${file}:${line}"
    echo "  - Draft comment: ${msg}"
  } >> "$proposed_comments_md"
  printf '%s\t%s\t%s\t%s\n' "medium" "$file" "$line" "$msg" >> "$proposed_comments_tsv"
  bug_model_risk_fallback_injected=1
}

run_repo_bug_model_rules_only() {
  local resolved_cmd=""
  local model_raw=""
  local model_json_payload=""
  local single_commit=""
  local location_text="model-scorer"
  local action_text=""
  local predicted_flag="false"
  local scorer_args=()
  local review_comments_out="$context_dir/review_comments.md"
  local artifact_out_dir="$context_dir"

  if [[ "$ruleset_mode" != "repo-bug-model-rules" ]]; then
    return 0
  fi

  resolve_bug_model_defaults || true
  [[ -n "$bug_model_path" ]] || err "No bug model available for --ruleset repo-bug-model-rules. Install ml-bug-feature-models and run its install.sh, or pass --bug-model."
  [[ -f "$bug_model_path" ]] || err "Bug model not found: $bug_model_path"

  resolved_cmd="$(resolve_bug_scorer_cmd || true)"
  [[ -n "$resolved_cmd" ]] || err "Unable to resolve scorer command. Install ml-bug-feature-models, set BUG_SCORER_CMD, or pass --bug-scorer-cmd."

  read -r -a scorer_args <<< "$resolved_cmd"
  [[ "${#scorer_args[@]}" -gt 0 ]] || err "Invalid scorer command: $resolved_cmd"

  single_commit="$(jq -r 'if length==1 then .[0].sha // "" else "" end' "$commits_json")"
  if [[ -n "$single_commit" ]]; then
    model_raw="$("${scorer_args[@]}" \
      --model "$bug_model_path" \
      --repo "$repo_dir" \
      --mode head \
      --commit "$single_commit" \
      --binary-threshold "$bug_binary_threshold" \
      --family-threshold "$bug_family_threshold" \
      --hunk-threshold "$bug_hunk_threshold" \
      --topk-hunks "$bug_topk_hunks" \
      --json 2>>"$kernel_vuln_log" || true)"
  else
    model_raw="$("${scorer_args[@]}" \
      --model "$bug_model_path" \
      --repo "$repo_dir" \
      --mode range \
      --range "$base_ref..$head_ref" \
      --binary-threshold "$bug_binary_threshold" \
      --family-threshold "$bug_family_threshold" \
      --hunk-threshold "$bug_hunk_threshold" \
      --topk-hunks "$bug_topk_hunks" \
      --json 2>>"$kernel_vuln_log" || true)"
  fi

  model_json_payload="$(printf '%s\n' "$model_raw" | sed -n '/^{/,$p')"
  [[ -n "$model_json_payload" ]] || err "Model scorer returned empty output"
  printf '%s\n' "$model_json_payload" > "$bug_model_json"
  jq -e . "$bug_model_json" >/dev/null 2>&1 || err "Model scorer returned invalid JSON"

  bug_model_ran=1
  bug_model_status="ok"
  bug_model_risk_score="$(jq -r '.bug_risk_score // 0' "$bug_model_json")"
  bug_model_review_mode="$(jq -r '.review_mode // ""' "$bug_model_json")"
  bug_model_family="$(jq -r '.predicted_bug_family // ""' "$bug_model_json")"
  bug_model_family_score="$(jq -r '.predicted_bug_family_score // 0' "$bug_model_json")"
  bug_model_best_hunk_score="$(jq -r '.best_hunk_score // 0' "$bug_model_json")"
  bug_model_hunk_file="$(jq -r '.hunks_topk[0].file // ""' "$bug_model_json")"
  bug_model_hunk_line="$(jq -r '.hunks_topk[0].line_hint // .hunks_topk[0].line_start // ""' "$bug_model_json")"
  bug_model_memory_used="$(jq -r '.memory_used // false' "$bug_model_json")"
  predicted_flag="$(jq -r '.predicted_bug_introducing // false' "$bug_model_json")"
  action_text="$(jq -r '.review_comments[0].detail // ""' "$bug_model_json")"
  if [[ -z "$action_text" ]]; then
    action_text="Run focused manual validation on top-ranked hunk and verify bug-family invariants."
  fi

  if [[ -n "$bug_model_hunk_file" && "$bug_model_hunk_line" =~ ^[0-9]+$ ]]; then
    location_text="${bug_model_hunk_file}:${bug_model_hunk_line}"
  fi

  if [[ "$bug_model_review_mode" == "actual-bug" && -n "$bug_model_family" ]]; then
    add_finding "high" "correctness" "$location_text" \
      "Model-assisted detector predicts ${bug_model_family} (risk=${bug_model_risk_score}, family=${bug_model_family_score}, hunk=${bug_model_best_hunk_score}, mode=${bug_model_review_mode}, memory_used=${bug_model_memory_used})." \
      "Likely ${bug_model_family} defect in this patch." \
      "$action_text" \
      "REPO-BUG-MODEL-RULE-1" "references/repo-bug-model-rules.md"
  elif [[ "$bug_model_review_mode" == "actual-bug-lite" && -n "$bug_model_family" ]]; then
    add_finding "high" "correctness" "$location_text" \
      "Model-assisted detector flagged ${bug_model_family} via lite gates (risk=${bug_model_risk_score}, family=${bug_model_family_score}, hunk=${bug_model_best_hunk_score}, mode=${bug_model_review_mode}, memory_used=${bug_model_memory_used})." \
      "Likely ${bug_model_family} defect in this patch; family confidence is below strict gate but localization and risk are actionable." \
      "$action_text" \
      "REPO-BUG-MODEL-RULE-1" "references/repo-bug-model-rules.md"
  elif [[ "$predicted_flag" == "true" ]]; then
    add_finding "medium" "correctness" "model-scorer" \
      "Model-assisted detector raised risk signal (risk=${bug_model_risk_score}, family=${bug_model_family:-unknown}, mode=${bug_model_review_mode})." \
      "Patch appears bug-prone but full family/localization gate did not pass." \
      "$action_text" \
      "REPO-BUG-MODEL-RULE-2" "references/repo-bug-model-rules.md"
  else
    add_finding "low" "process" "model-scorer" \
      "Model-assisted detector did not raise an actual-bug signal (risk=${bug_model_risk_score}, family=${bug_model_family:-unknown}, mode=${bug_model_review_mode:-n/a})." \
      "No strong model signal; manual review remains required." \
      "Treat this as informational only and continue standard review." \
      "REPO-BUG-MODEL-RULE-3" "references/repo-bug-model-rules.md"
  fi

  inject_high_risk_model_fallback_comment
  inject_risk_only_model_fallback_comment

  {
    high_count="$(grep -Ec '^### F[0-9]+ - HIGH - ' "$findings_md" || true)"
    medium_count="$(grep -Ec '^### F[0-9]+ - MEDIUM - ' "$findings_md" || true)"
    low_count="$(grep -Ec '^### F[0-9]+ - LOW - ' "$findings_md" || true)"
    comment_filter_reject_total_local="$(wc -l < "$comment_filter_rejects_tsv" | tr -d ' ')"
    echo "# PR Review Report"
    echo
    if [[ -n "$pr_url" ]]; then
      echo "PR: ${pr_url}"
    elif [[ -n "$owner" && -n "$repo" && -n "$pr_number" ]]; then
      echo "PR: https://github.com/${owner}/${repo}/pull/${pr_number}"
    fi
    echo "Fetched at (UTC): ${fetched_at}"
    echo
    echo "## 1. Snapshot"
    echo "- Owner/Repo: ${owner}/${repo}"
    echo "- PR Number: ${pr_number}"
    echo "- Title: ${pr_title}"
    echo "- Base Branch: ${base_branch}"
    echo "- Head Branch: ${head_branch}"
    echo "- Local Diff Base/Head: ${base_ref}...${head_ref}"
    echo "- Ruleset mode: ${ruleset_mode}"
    echo "- Autonomous Findings: high=${high_count} medium=${medium_count} low=${low_count}"
    echo "- Precision filter drops: ${comment_filter_reject_total_local}"
    echo "- Precision re-anchors: ${comment_reanchored_total}"
    echo
    echo "## 2. Changed Files"
    echo "| File | Status | + | - |"
    echo "| --- | --- | --- | --- |"
    if [[ -s "$files_rows_md" ]]; then
      cat "$files_rows_md"
    else
      echo "| (none) | - | - | - |"
    fi
    echo
    echo "## 3. repo-bug-model-rules"
    echo "- Model status: ${bug_model_status}"
    echo "- Model path: ${bug_model_path}"
    echo "- Model source: ${bug_model_source}"
    echo "- Thresholds: binary=${bug_binary_threshold}, family=${bug_family_threshold}, hunk=${bug_hunk_threshold}, topk_hunks=${bug_topk_hunks}"
    echo "- Review mode: ${bug_model_review_mode:-n/a}"
    echo "- Predicted family: ${bug_model_family:-unknown} (score=${bug_model_family_score})"
    echo "- Risk score: ${bug_model_risk_score}"
    echo "- Top hunk: ${bug_model_hunk_file:-n/a}:${bug_model_hunk_line:-n/a} (confidence=${bug_model_best_hunk_score})"
    echo
    echo "## 4. Prioritized Findings"
    cat "$findings_md"
    echo
    echo "## 5. Proposed Review Comments (Human Approval Required)"
    echo "- Precision filter drops: ${comment_filter_reject_total_local}"
    echo "- Precision re-anchors: ${comment_reanchored_total}"
    if [[ -s "$proposed_comments_md" ]]; then
      cat "$proposed_comments_md"
    else
      echo "- No draft comments generated."
    fi
  } > "$report_md"

  {
    echo "# Draft Review Comments"
    echo
    echo "PR: ${owner}/${repo} #${pr_number} - ${pr_title}"
    echo
    echo "_Draft-only until human approval._"
    echo
    if [[ -s "$proposed_comments_tsv" ]]; then
      cidx=0
      while IFS=$'\t' read -r sev file line msg; do
        link="$(build_comment_permalink "$file" "$line" || true)"
        cidx=$((cidx + 1))
        echo "## C${cidx}"
        echo "- Severity: ${sev^^}"
        echo "- Location: ${file}:${line}"
        if [[ -n "$link" ]]; then
          echo "- Link: ${link}"
        fi
        echo "- Comment: ${msg}"
        echo
      done < "$proposed_comments_tsv"
    else
      echo "- No draft comments generated."
    fi
  } > "$review_comments_md"

  if [[ -n "$report_file" ]]; then
    cp "$report_md" "$report_file"
    review_comments_out="$(dirname "$report_file")/review_comments.md"
    artifact_out_dir="$(dirname "$report_file")"
  elif [[ -n "$output_file" ]]; then
    cp "$report_md" "$output_file"
    review_comments_out="$(dirname "$output_file")/review_comments.md"
    artifact_out_dir="$(dirname "$output_file")"
  else
    cat "$report_md"
  fi
  cp "$review_comments_md" "$review_comments_out"
  if [[ "$flawfinder_ran" -eq 1 ]]; then
    cp "$flawfinder_raw_tsv" "$artifact_out_dir/flawfinder_findings.tsv"
  fi
  exit 0
}

resolve_bug_model_defaults || true
run_repo_bug_model_rules_only

# Autonomous findings from patch content (primary signal).
while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "high" "correctness" "$loc" "Added line uses unsafe C string API: ${text}" "Potential memory corruption or overflow in runtime paths." "Replace with bounded alternatives and enforce explicit size checks."
done < <(awk -F'\t' '($3 ~ /(^|[^A-Za-z_])(strcpy|strcat|sprintf|vsprintf|gets)[[:space:]]*\(/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,10p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Added dynamic allocation path: ${text}" "Allocation failure path may be unhandled, causing null dereference or leaks." "Add explicit NULL handling and cleanup path checks around this allocation site."
done < <(awk -F'\t' '($3 ~ /\<(malloc|calloc|realloc)[[:space:]]*\(/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,12p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "maintainability" "$loc" "Added raw memory copy operation: ${text}" "Length/source validation may be insufficient for malformed inputs." "Confirm source/destination bounds and use validated size values before copy."
done < <(awk -F'\t' '($3 ~ /\<(memcpy|memmove)[[:space:]]*\(/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,12p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Added request payload handling line: ${text}" "Parsing logic can regress under malformed or short payloads." "Validate length/endianness early and reject invalid payloads before dereferencing or parsing."
done < <(awk -F'\t' '($3 ~ /(request_data|payload|msg_data).*(\(|\[|->|\.)/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,12p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Unchecked return-value candidate in changed line: ${text}" "Silent failures can bypass error handling and surface later as corrupted state." "Capture and verify return values for fallible operations; propagate explicit error codes."
done < <(awk -F'\t' '
($3 ~ /\<(snprintf|vsnprintf|read|write|recv|send|fread|fwrite|close|pthread_mutex_lock|pthread_mutex_unlock)\s*\(/ &&
 $3 !~ /=/ && $3 !~ /if[[:space:]]*\(/ && $3 !~ /return[[:space:]]/) {print $1 "\t" $2 "\t" $3}
' "$added_lines_tsv" | sed -n '1,12p')

if [[ "$diff_native_heuristics" == "1" ]]; then
  # Diff-native: detect deleted/relaxed guards and anchor findings to nearby added lines.
  while IFS=$'\t' read -r file old_line old_text; do
    [[ -n "$file" && "$old_line" =~ ^[0-9]+$ ]] || continue
    case "$file" in
      *.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.hh) ;;
      *)
        continue
        ;;
    esac
    anchor_line="$(list_candidate_changed_lines "$file" "$old_line" "$diff_native_window" | head -n1 || true)"
    [[ "$anchor_line" =~ ^[0-9]+$ ]] || continue
    if [[ "$diff_native_strict" == "1" ]]; then
      anchor_text="$(awk -F'\t' -v f="$file" -v l="$anchor_line" '($1==f && $2==l){print $3; exit}' "$added_lines_tsv")"
      if ! printf '%s\n' "$anchor_text" | grep -Eqi '(\->|\[[^]]+\]|<[[:space:]]*[[:alnum:]_]+|>[[:space:]]*[[:alnum:]_]+|\b[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(|\b(memcpy|memmove|strcpy|strncpy|EFI_ERROR|IS_ERR|IS_ERR_OR_NULL)\b)'; then
        continue
      fi
    fi
    has_replacement_guard="$(awk -F'\t' -v f="$file" -v l="$anchor_line" '
($1 == f && $2 ~ /^[0-9]+$/) {
  d = $2 - l
  if (d < 0) d = -d
  if (d <= 2 && $3 ~ /(if[[:space:]]*\(|WARN_ON|BUG_ON|IS_ERR|IS_ERR_OR_NULL|<=|>=|==|!=|<[[:space:]]*[[:alnum:]_]|>[[:space:]]*[[:alnum:]_]/)) {
    found = 1
  }
}
END { print (found ? "1" : "0") }
' "$added_lines_tsv")"
    if [[ "$has_replacement_guard" == "1" ]]; then
      continue
    fi
    loc="${file}:${anchor_line}"
    add_finding "high" "correctness" "$loc" \
      "Potential deleted/relaxed safety guard near changed code. Removed line: ${old_text}" \
      "Removed validation/guard logic can re-open null/bounds/state safety regressions." \
      "Reintroduce equivalent guard semantics near the modified path and add regression coverage for the removed condition." \
      "LNX-DIFF-GUARD-RELAX" "https://www.kernel.org/doc/html/latest/process/coding-style.html"
  done < <(awk -F'\t' '
($3 ~ /\bif[[:space:]]*\(/ &&
 $3 ~ /(!|NULL|IS_ERR|IS_ERR_OR_NULL|<=|>=|==|!=|<[[:space:]]*[[:alnum:]_]|>[[:space:]]*[[:alnum:]_]|WARN_ON|BUG_ON|return|goto)/) ||
($3 ~ /(WARN_ON|BUG_ON|IS_ERR|IS_ERR_OR_NULL)[[:space:]]*\(/) ||
($3 ~ /\b(return|goto)[[:space:]]+/ && $3 ~ /(-E[A-Z0-9_]+|NULL|false|0)/) {
  print $1 "\t" $2 "\t" $3
}
' "$deleted_lines_tsv" | sed -n "1,${diff_native_max_findings}p")

  # Diff-native: detect changed call sites where prior checked status handling was dropped.
  awk -F'\t' '
function is_comment_line(s,    t) {
  t = s
  gsub(/^[[:space:]]+/, "", t)
  return (t ~ /^(\/\/|\/\*|\*|#|@)/)
}
function valid_call_name(n) {
  if (n == "" || n ~ /^(if|for|while|switch|return|sizeof)$/) return 0
  if (n ~ /^[A-Z0-9_]+$/) return 0
  return 1
}
function extract_call(s,   t, m) {
  t = s
  if (match(t, /([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(/, m)) return m[1]
  return ""
}
{
  if (is_comment_line($3)) next
  if ($1 !~ /\.(c|h|cc|cpp|cxx|hpp|hh)$/) next
  call = extract_call($3)
  if (!valid_call_name(call)) next
  if ($3 ~ /if[[:space:]]*\(.*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/ || $3 ~ /=[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/ || $3 ~ /return[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/) {
    print $1 "\t" call
  }
}
' "$deleted_lines_tsv" | sort -u > "$diff_native_checked_calls_tsv"

  diff_native_unchecked_emitted=0
  while IFS=$'\t' read -r file line text call; do
    [[ -n "$file" && "$line" =~ ^[0-9]+$ && -n "$call" ]] || continue
    case "$file" in
      *.c|*.h|*.cc|*.cpp|*.cxx|*.hpp|*.hh) ;;
      *)
        continue
        ;;
    esac
    if ! grep -Fqx -- "$(printf '%s\t%s' "$file" "$call")" "$diff_native_checked_calls_tsv"; then
      continue
    fi
    loc="${file}:${line}"
    add_finding "medium" "correctness" "$loc" \
      "Changed call site may have dropped prior status handling for '${call}': ${text}" \
      "Unchecked failures can silently propagate corrupted state and hide root-cause signals." \
      "Capture and validate '${call}' return status (or equivalent error indicator) before continuing control flow." \
      "LNX-DIFF-UNCHECKED-RET" "https://go.dev/wiki/CodeReviewComments#handle-errors"
    diff_native_unchecked_emitted=$((diff_native_unchecked_emitted + 1))
    if [[ "$diff_native_unchecked_emitted" -ge "$diff_native_max_findings" ]]; then
      break
    fi
  done < <(awk -F'\t' '
function is_comment_line(s,    t) {
  t = s
  gsub(/^[[:space:]]+/, "", t)
  return (t ~ /^(\/\/|\/\*|\*|#|@)/)
}
function valid_call_name(n) {
  if (n == "" || n ~ /^(if|for|while|switch|return|sizeof)$/) return 0
  if (n ~ /^[A-Z0-9_]+$/) return 0
  return 1
}
function extract_call(s,   t, m) {
  t = s
  if (match(t, /([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(/, m)) return m[1]
  return ""
}
{
  if (is_comment_line($3)) next
  if ($1 !~ /\.(c|h|cc|cpp|cxx|hpp|hh)$/) next
  call = extract_call($3)
  if (!valid_call_name(call)) next
  if ($3 ~ /if[[:space:]]*\(/ || $3 ~ /^[[:space:]]*(for|while|switch)[[:space:]]*\(/ || $3 ~ /return[[:space:]]+/ || $3 ~ /=[^=]/) next
  print $1 "\t" $2 "\t" $3 "\t" call
}
' "$added_lines_tsv")
fi

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "high" "correctness" "$loc" "Potential divide/modulo without obvious zero-guard: ${text}" "Division by zero can crash runtime paths and trigger undefined behavior." "Add explicit denominator validation before arithmetic operations."
done < <(awk -F'\t' '
($3 ~ /[[:alnum:]_]\s*\/\s*[[:alnum:]_]/ || $3 ~ /[[:alnum:]_]\s*%\s*[[:alnum:]_]/) &&
 $3 !~ /\/\// && $3 !~ /if[[:space:]]*\(.*[!=<>]=?[[:space:]]*0/ {print $1 "\t" $2 "\t" $3}
' "$added_lines_tsv" | sed -n '1,8p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "maintainability" "$loc" "Public API/header surface change detected: ${text}" "API surface changes may break downstream consumers or ABI assumptions." "Confirm compatibility guarantees, update API docs, and call out migration impact in release notes."
done < <(awk -F'\t' '
($1 ~ /\.(h|hpp)$/) &&
($3 ~ /^[[:space:]]*(extern[[:space:]]+)?(const[[:space:]]+)?(void|int|long|short|char|bool|size_t|ssize_t|uint[0-9]+_t|int[0-9]+_t|struct[[:space:]]+[[:alnum:]_]+)[[:space:]\*]+[[:alnum:]_]+[[:space:]]*\(/) {
  print $1 "\t" $2 "\t" $3
}' "$added_lines_tsv" | sed -n '1,10p')

# Callback and API contract heuristics (captures common human-review signals).
while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "high" "correctness" "$loc" "Callback pointer dereference without obvious function-pointer guard: ${text}" "A NULL callback pointer can crash at runtime in normal request paths." "Validate both ops container and callback pointer (e.g., ops && ops->fn) before invocation and fail gracefully." "API-CB-NULLCHECK" "https://google.github.io/eng-practices/review/reviewer/looking-for.html#functionality"
done < <(awk -F'\t' '
($3 ~ /->[[:alnum:]_]+->[[:alnum:]_]+[[:space:]]*\(/) &&
($3 !~ /if[[:space:]]*\(.*->[[:alnum:]_]+->[[:alnum:]_]+/) {
  print $1 "\t" $2 "\t" $3
}' "$added_lines_tsv" | sed -n '1,10p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "maintainability" "$loc" "Platform callback in public ops struct returns void: ${text}" "Callers cannot propagate platform failure causes, reducing diagnosability and control-flow safety." "Prefer error-returning callback contracts for state-changing operations and map failures to protocol error codes." "API-CB-RETVAL" "https://go.dev/wiki/CodeReviewComments#handle-errors"
done < <(awk -F'\t' '
($1 ~ /\.(h|hpp)$/) &&
($0 ~ /^[^\t]+\t[0-9]+\t.*void[[:space:]]*\(\*[[:alnum:]_]*do_[[:alnum:]_]+\)/) {
  print $1 "\t" $2 "\tvoid-callback-signature"
}' "$added_lines_tsv" | sed -n '1,8p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Raw request payload is forwarded to callback without local unpack/validation: ${text}" "Deferring parsing/endianness to platform callbacks can create inconsistent behavior and fragile API contracts." "Decode request fields in service-layer code and pass typed, validated parameters to callbacks." "API-ENDIAN-DECODE" "https://google.github.io/eng-practices/review/reviewer/looking-for.html#design"
done < <(awk -F'\t' '
($0 ~ /^[^\t]+\t[0-9]+\t.*(do_[[:alnum:]_]+|set_[[:alnum:]_]+)[[:space:]]*\(.*request_data/) {
  print $1 "\t" $2 "\trequest-data-forwarded"
}' "$added_lines_tsv" | sed -n '1,8p')

while IFS=$'\t' read -r file line count; do
  [[ "$count" == "1" ]] || continue
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Request length argument appears only in function signature and is otherwise unused." "Payload parsing without explicit length checks can allow malformed or truncated request handling bugs." "Validate and consume request length before parsing payload bytes or forwarding payload pointers." "API-REQ-DATALEN" "https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html"
done < <(awk -F'\t' '
($3 ~ /\<request_datalen\>/) {
  cnt[$1]++
  if (!(first_line[$1])) first_line[$1]=$2
}
END {
  for (f in cnt) print f "\t" first_line[f] "\t" cnt[f]
}' "$added_lines_tsv")

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Function initializes a constant success code and returns it after callback invocation." "Callback failures may be silently ignored, causing protocol responses to report success on failure paths." "Return callback status (or translated protocol error) instead of unconditional success defaults." "API-CB-STATUS-PROP" "https://go.dev/wiki/CodeReviewComments#handle-errors"
done < <(awk -F'\t' '
{
  f=$1; l=$2; t=$3
  if (t ~ /enum[[:space:]]+[[:alnum:]_]+[[:space:]]+ret[[:space:]]*=[[:space:]]*0[[:space:]]*;/) ret_line[f]=l
  if (t ~ /->[[:alnum:]_]+->[[:alnum:]_]+[[:space:]]*\(/) cb_call[f]=1
  if (t ~ /return[[:space:]]+ret[[:space:]]*;/) ret_return[f]=1
}
END {
  for (f in ret_line) {
    if (cb_call[f] && ret_return[f]) print f "\t" ret_line[f] "\tconstant-ret-after-callback"
  }
}' "$added_lines_tsv" | sed -n '1,8p')

cb_sig_loc="$(awk -F'\t' '
($1 ~ /\.(h|hpp)$/) &&
($0 ~ /^[^\t]+\t[0-9]+\t.*void[[:space:]]*\(\*do_set_logging\)\(void[[:space:]]*\*priv,[[:space:]]*void[[:space:]]*\*data,[[:space:]]*rpmi_uint8_t[[:space:]]*is_be\)/) {
  print $1 ":" $2
  exit
}' "$added_lines_tsv")"

has_set_state_handler="$(awk -F'\t' '
($1 ~ /\.(c|cc|cpp)$/) &&
($3 ~ /rpmi_[A-Za-z0-9_]+_set_state/) {found=1}
END {print (found ? "true" : "false")}' "$added_lines_tsv")"

if [[ -n "$cb_sig_loc" && "$has_set_state_handler" == "true" ]]; then
  add_finding "low" "maintainability" "$cb_sig_loc" \
    "Callback name appears inconsistent with local set-state handler naming (do_set_logging vs *_set_state)." \
    "Naming drift can obscure interface intent and increase review/maintenance overhead." \
    "Align callback naming with local handler convention (for example do_set_state) or document why naming intentionally differs." \
    "API-CB-NAMING-ALIGN" "https://go.dev/wiki/CodeReviewComments#initialisms"
fi

has_req_datalen="$(awk -F'\t' '($3 ~ /\<request_datalen\>/) {found=1} END{print (found ? "true" : "false")}' "$added_lines_tsv")"
has_req_forward="$(awk -F'\t' '($3 ~ /set_[A-Za-z0-9_]+[[:space:]]*\(.*request_data/) {found=1} END{print (found ? "true" : "false")}' "$added_lines_tsv")"
if [[ -n "$cb_sig_loc" && "$has_req_datalen" == "true" && "$has_req_forward" == "true" ]]; then
  add_finding "medium" "correctness" "$cb_sig_loc" \
    "Callback contract currently forwards raw request pointer/endianness instead of typed decoded fields." \
    "Opaque callback payload contracts can hide parsing bugs and make platform implementations inconsistent." \
    "Prefer a typed callback contract after local decode/unpack (for example do_set_logging(void *priv, uint32_t log_type, uint32_t datalen_bytes, void *data))." \
    "API-CB-TYPED-SIGNATURE" "https://google.github.io/eng-practices/review/reviewer/looking-for.html#design"
fi

while IFS=$'\t' read -r file line group text; do
  [[ -n "$file" && -n "$line" && -n "$group" ]] || continue
  low=$((line - 80))
  high=$((line + 80))
  [[ "$low" -lt 1 ]] && low=1
  if ! awk -v low="$low" -v high="$high" -v g="$group" '
    NR >= low && NR <= high {
      s = tolower($0)
      if (s ~ /\\defgroup/ && s ~ g) { found=1 }
    }
    END { exit(found ? 0 : 1) }
  ' "$repo_dir/$file"; then
    loc="${file}:${line}"
    add_finding "low" "maintainability" "$loc" "New service-ID enum added without nearby Doxygen group marker for this service family." "Missing group-level docs reduce discoverability and consistency for generated API documentation." "Add/update a \\defgroup section for this service group close to the new enum/API block." "DOC-API-GROUP" "https://www.doxygen.nl/manual/commands.html#cmddefgroup"
  fi
done < <(awk -F'\t' '
($1 ~ /\.(h|hpp)$/ && $3 ~ /^[[:space:]]*enum[[:space:]]+rpmi_[[:alnum:]_]+_service_id[[:space:]]*\{/) {
  grp=$3
  gsub(/^[[:space:]]*enum[[:space:]]+rpmi_/, "", grp)
  gsub(/_service_id[[:space:]]*\{.*/, "", grp)
  print $1 "\t" $2 "\t" tolower(grp) "\t" $3
}' "$added_lines_tsv" | sed -n '1,8p')

# Cross-repo best-practice heuristics.
while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "high" "correctness" "$loc" "Potential hardcoded secret/credential material in added line: ${text}" "Credentials or sensitive data may leak via source control and build artifacts." "Remove embedded secrets and use runtime secret management/env injection."
done < <(awk -F'\t' '($3 ~ /(AKIA[0-9A-Z]{16}|BEGIN[[:space:]]+PRIVATE[[:space:]]+KEY|password[[:space:]]*=|passwd[[:space:]]*=|api[_-]?key[[:space:]]*=|secret[[:space:]]*=|token[[:space:]]*=)/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,10p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "testing-gap" "$loc" "Added test skip/disable marker: ${text}" "Coverage may hide regressions by skipping critical paths." "Document rationale and add a tracking issue with removal criteria for each skip/disable."
done < <(awk -F'\t' '($3 ~ /(it\.skip|describe\.skip|@Disabled|pytest\.mark\.skip|xfail|t\.Skip\(|[[:space:]]skip[[:space:]]*\()/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,10p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "maintainability" "$loc" "Added debug/log artifact in patch: ${text}" "Transient debug statements may leak internal state or increase production noise." "Remove debug-only traces or guard them behind explicit debug flags."
done < <(awk -F'\t' '($3 ~ /(console\.log\(|debugger;|pdb\.set_trace\(|fmt\.Print(f|ln)?\(|System\.out\.print(ln)?\()/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,10p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "correctness" "$loc" "Broad exception handling added: ${text}" "Overly broad catches can hide real failures and reduce debuggability." "Catch explicit exception types and preserve actionable error context."
done < <(awk -F'\t' '($1 !~ /\.(plugin|Plugin|tool|Tool|script|Script|pytool|check|Check|util|Util)/ && $1 !~ /^\.github\/|^\.pytool\/|^\.azurepipelines\/|^BaseTools\/Scripts\/|^BaseTools\/Plugin\// && $3 ~ /(except[[:space:]]+Exception|catch[[:space:]]*\([[:space:]]*Exception[[:space:]]*[a-zA-Z0-9_]*[[:space:]]*\)|catch[[:space:]]*\(\.\.\.\)|rescue[[:space:]]+StandardError)/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,10p')

# Medium severity: source changed without tests touched.
code_changed="$(jq -r 'any(.[]; (.filename|test("^(src/|lib/|core/|pkg/|cmd/|kernel/|drivers/|arch/|include/)")))' "$files_json")"
tests_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(test|tests|testing|spec|specs)/|(_test\\.|\\.spec\\.)")))' "$files_json")"
if [[ "$code_changed" == "true" && "$tests_changed" != "true" ]]; then
  add_finding "medium" "testing-gap" "changed-files" "Source paths changed but no obvious test files were changed." "Regression risk is higher without direct test coverage updates." "Add/extend tests for modified behavior or document why existing coverage is sufficient." "NODE-PR-STEP6" "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#step-6-test"
fi

# Medium severity: large PR heuristics.
if [[ "$files_count" -gt 25 || "$total_additions" -gt 800 ]]; then
  add_finding "medium" "process" "pr-scope" "PR touches ${files_count} files with +${total_additions}/-${total_deletions} lines." "Large review scope can hide defects and reduce review quality." "Split into smaller logical commits/PRs or provide stronger per-area validation evidence."
fi

docs_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(docs|doc|documentation)/|README|CHANGELOG|\\.md$")))' "$files_json")"
if [[ "$code_changed" == "true" && "$docs_changed" != "true" ]]; then
  add_finding "low" "maintainability" "changed-files" "Code changed without obvious docs/changelog updates." "Operational or API behavior changes may be under-documented for maintainers/users." "Add targeted README/API/changelog updates where behavior or usage changed." "PY-PR-DOCS" "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
fi

# Extensive review topic coverage (cross-repo, language-agnostic).
api_surface_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(include|public|api|apis|interface|interfaces|proto|openapi|swagger)/|\\.h$|\\.hpp$|\\.proto$")))' "$files_json")"
ci_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(\\.github/workflows|\\.gitlab-ci|ci/|\\.ci/)|Jenkinsfile|azure-pipelines|buildkite|cirrus")))' "$files_json")"
deps_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(go\\.mod|go\\.sum|Cargo\\.toml|Cargo\\.lock|package\\.json|package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|pyproject\\.toml|requirements.*\\.txt|Pipfile|pom\\.xml|build\\.gradle|Gemfile|composer\\.json)$")))' "$files_json")"
security_area_changed="$(jq -r 'any(.[]; (.filename|ascii_downcase|test("security|auth|crypto|tls|ssl|secret|token|password|permission|acl|x509|jwt|oauth")))' "$files_json")"
db_schema_changed="$(jq -r 'any(.[]; (.filename|ascii_downcase|test("migrations?|schema|ddl|database|db/|sql/|\\.sql$")))' "$files_json")"
release_notes_changed="$(jq -r 'any(.[]; (.filename|test("CHANGELOG|NEWS|RELEASE|release-notes|notes/")))' "$files_json")"
ownership_files_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(MAINTAINERS|OWNERS|CODEOWNERS)$")))' "$files_json")"
license_files_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(LICENSE|COPYING|NOTICE)")))' "$files_json")"
news_changed="$(jq -r 'any(.[]; (.filename|test("(^|/)(Misc/NEWS\\.d/|NEWS|WHATSNEW|release[-_ ]notes?|CHANGELOG)")))' "$files_json")"
issue_ref_present="false"
if printf '%s' "$pr_body" | grep -Eqi '(fixes|fixed|closes|closed|resolves|resolved)[[:space:]]+#|https?://github.com/.+/issues/[0-9]+'; then
  issue_ref_present="true"
fi

# Research-driven semantic governance checks (cross-repo, reviewer-level signals).
commit_has_rationale="$(jq -r 'any(.[]; (.commit.message // "" | test("(because|so that|in order to|rationale|reason|impact|regression|root cause|why)"; "i")))' "$commits_json")"
commit_subject_generic="$(jq -r 'any(.[]; ((.commit.message // "" | split("\n")[0]) | test("^(fix|update|changes|misc|wip|tmp|temp)$"; "i")))' "$commits_json")"
api_version_signal_changed="false"
if git -C "$repo_dir" diff "$base_ref...$head_ref" | rg -q '^[+-].*(ABI|API|SPEC|VERSION|compat|compatibility)'; then
  api_version_signal_changed="true"
fi

if [[ "$commit_has_rationale" != "true" && "$issue_ref_present" != "true" ]]; then
  add_finding "medium" "process" "commit-metadata" "Commit/PR metadata lacks strong problem+rationale signal (no issue link and no clear rationale terms)." "Weak rationale makes design validation and regression triage harder during maintenance." "Strengthen commit message/PR description with problem statement, root cause, constraints, and why this design was chosen." "QEMU-SUBMIT-COMMIT" "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#write-a-meaningful-commit-message"
fi

if [[ "$commit_subject_generic" == "true" ]]; then
  add_finding "low" "maintainability" "commit-metadata" "At least one commit subject appears generic (e.g., fix/update/misc)." "Generic subjects reduce traceability when bisecting and auditing history." "Use subsystem-scoped, intent-revealing commit subjects with explicit functional context." "NODE-PR-COMMITMSG" "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#commit-message-guidelines"
fi

if [[ "$api_surface_changed" == "true" && "$tests_changed" != "true" ]]; then
  add_finding "high" "testing-gap" "api-surface" "Public API/header surface changed without obvious test updates." "API regressions can ship undetected when interface changes are not validated by contract/regression tests." "Add or extend API-level regression tests covering success and failure paths for the changed interface." "GOOG-LOOK-TESTS" "https://google.github.io/eng-practices/review/reviewer/looking-for.html#tests"
fi

if [[ "$api_surface_changed" == "true" && "$docs_changed" != "true" ]]; then
  add_finding "medium" "maintainability" "api-surface" "Public API/header surface changed without obvious API-doc updates." "Consumers may misuse new/changed interfaces without updated docs and examples." "Update API docs with semantics, constraints, and error behavior for the changed interfaces." "RUST-C-QUESTION-MARK" "https://rust-lang.github.io/api-guidelines/checklist.html"
fi

if [[ "$api_surface_changed" == "true" && "$release_notes_changed" != "true" ]]; then
  add_finding "medium" "process" "api-surface" "Public API/header changes detected without release-note style signal." "Downstream integrators may miss migration or compatibility impact." "Add a release-note/changelog entry describing API impact and migration expectations." "RUST-C-RELNOTES" "https://rust-lang.github.io/api-guidelines/checklist.html#c-relnotes"
fi

if [[ "$api_surface_changed" == "true" && "$api_version_signal_changed" != "true" ]]; then
  add_finding "low" "maintainability" "api-surface" "API/interface changes detected without obvious version/compatibility signal in patch." "Compatibility intent may be unclear for downstream maintainers." "Document compatibility expectations explicitly or update version/compat metadata where project policy requires." "PY-COMMIT-COMPAT" "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
fi

while IFS=$'\t' read -r file line text has_cmp; do
  [[ -n "$file" && -n "$line" ]] || continue
  if [[ "$has_cmp" != "1" ]]; then
    loc="${file}:${line}"
    add_finding "high" "correctness" "$loc" "Raw request payload processing detected without nearby request-length guard in changed lines." "Insufficient boundary validation can enable malformed-input parsing bugs and memory-safety issues." "Validate request length boundaries before parsing/unpacking payload data." "OWASP-IV-LEN-GUARD" "https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html"
  fi
done < <(awk -F'\t' '
{
  f=$1; l=$2; t=$3
  if (t ~ /\<request_data\>/ && !(first_req_line[f])) first_req_line[f]=l
  if (t ~ /\<request_datalen\>/ && t ~ /(<=|>=|==|!=|<|>)/) has_cmp[f]=1
}
END {
  for (f in first_req_line) print f "\t" first_req_line[f] "\trequest-data\t" (has_cmp[f] ? 1 : 0)
}' "$added_lines_tsv" | sed -n '1,10p')

while IFS=$'\t' read -r file line text; do
  [[ -n "$file" && -n "$line" ]] || continue
  if ! rg -q 'free_lock[[:space:]]*\(' "$repo_dir/$file"; then
    loc="${file}:${line}"
    add_finding "medium" "correctness" "$loc" "Lock allocation detected without matching free_lock usage in file-level implementation." "Missing lock cleanup can cause leaks or teardown-time instability." "Ensure lock lifecycle symmetry (alloc/init and free/destroy) across create/destroy paths." "GO-CR-GOROUTINES" "https://go.dev/wiki/CodeReviewComments#goroutine-lifetimes"
  fi
done < <(awk -F'\t' '($3 ~ /alloc_lock[[:space:]]*\(/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,8p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "medium" "security" "$loc" "Potential sensitive payload/credential data in logging/debug output: ${text}" "Security logs can leak secrets/PII and create secondary disclosure risk." "Redact secrets and avoid dumping raw payloads/credentials in logs." "OWASP-LOG-SENSITIVE" "https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html"
done < <(awk -F'\t' '
($3 ~ /(\<printf\>|\<fprintf\>|\<syslog\>|\<pr_(info|warn|err|debug)\>|\<log_(info|warn|error|debug)\>|\<logger\>|\<trace\>|DPRINTF[[:space:]]*\()/) &&
($3 ~ /(request_data|payload|token|secret|password|passwd|authorization|auth)/) {
  print $1 "\t" $2 "\t" $3
}' "$added_lines_tsv" | sed -n '1,8p')

while IFS=$'\t' read -r file line text; do
  loc="${file}:${line}"
  add_finding "high" "security" "$loc" "Potential authorization/authentication bypass control detected: ${text}" "Bypass toggles in production paths can disable security boundaries." "Gate bypass behavior to test-only codepaths and enforce deny-by-default authorization checks." "OWASP-AUTHZ-DENY-DEFAULT" "https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html"
done < <(awk -F'\t' '
($3 ~ /(skip_auth|bypass_auth|allow_all|permit_all|auth_disabled|disable_auth|no_auth|is_admin[[:space:]]*=[[:space:]]*1|authorized[[:space:]]*=[[:space:]]*1)/) {
  print $1 "\t" $2 "\t" $3
}' "$added_lines_tsv" | sed -n '1,8p')

# Medium severity: TODO/FIXME added in diff (when local refs are available).
todo_lines="$(git -C "$repo_dir" diff "$base_ref...$head_ref" | rg -n '^\+.*(TODO|FIXME|XXX)' || true)"
if [[ -n "$todo_lines" ]]; then
  trimmed="$(printf '%s' "$todo_lines" | sed -n '1,3p' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
  add_finding "medium" "maintainability" "diff-added-lines" "$trimmed" "New deferred-work markers may ship unresolved work." "Resolve or track each TODO/FIXME with linked issue IDs and clear ownership."
fi

# Kernel-vuln rule pass (Phase 1): data-derived seed rules from historical bug corpora.
if command -v python3 >/dev/null 2>&1 && [[ -f "$kernel_vuln_rules_json" ]] && [[ -x "$script_dir/apply_kernel_vuln_rules.py" ]]; then
  kernel_vuln_rules_ran=1
  if python3 "$script_dir/apply_kernel_vuln_rules.py" \
    --added-lines-tsv "$added_lines_tsv" \
    --rules-json "$kernel_vuln_rules_json" \
    --repo-dir "$repo_dir" \
    --files-json "$files_json" > "$kernel_vuln_raw_tsv" 2>>"$kernel_vuln_log"; then
    if [[ -s "$kernel_vuln_raw_tsv" ]]; then
      kernel_vuln_findings_total="$(wc -l < "$kernel_vuln_raw_tsv" | tr -d ' ')"
      while IFS=$'\t' read -r sev cat loc evidence risk action rid rsrc rconf; do
        [[ -n "$sev" && -n "$loc" ]] || continue
        add_finding "$sev" "$cat" "$loc" "${evidence} (confidence=${rconf})" "$risk" "$action" "$rid" "$rsrc"
      done < "$kernel_vuln_raw_tsv"
    fi
  fi
fi

# Existing reviewer comments are context by default; include as findings only when requested.
# Flawfinder static analysis pass: runs on changed C/C++ source files and stores findings
# for post-model deduplication before comment emission.
if command -v flawfinder >/dev/null 2>&1; then
  flawfinder_ran=1
  flawfinder_minlevel="${FLAWFINDER_MINLEVEL:-4}"
  all_ff_files="$(jq -r '.[] | .filename // empty' "$files_json" 2>/dev/null | grep -E '\.(c|h|cc|cpp|cxx|hpp|hh)$' | sort -u || true)"
  if [[ -n "$all_ff_files" ]]; then
    while IFS= read -r cfile; do
      abs_file="$repo_dir/$cfile"
      # Use head_ref version of the file for accurate line numbers
      ff_tmp_file="$tmp_dir/ff_$(printf '%s' "$cfile" | tr '/' '_').c"
      if git -C "$repo_dir" show "${head_ref}:${cfile}" > "$ff_tmp_file" 2>/dev/null; then
        abs_file="$ff_tmp_file"
      elif [[ ! -f "$abs_file" ]]; then
        continue
      fi
      # Build set of added line numbers for strict diff-adjacency filtering (<= +/-3)
      added_lines_for_file="$(awk -F'\t' -v f="$cfile" '$1==f && $2~/^[0-9]+$/ {print $2}' "$added_lines_tsv")"
      [[ -n "$added_lines_for_file" ]] || continue
      # Run flawfinder on the file, capture dataonly output
      ff_out="$(flawfinder --dataonly --quiet --minlevel "$flawfinder_minlevel" --singleline "$abs_file" 2>>"$flawfinder_log" || true)"
      [[ -n "$ff_out" ]] || continue
      # Parse flawfinder output: file:line:col: [level] (CWE-NNN) message
      while IFS= read -r ff_line; do
        [[ -z "$ff_line" ]] && continue
        ff_lineno="$(printf '%s' "$ff_line" | sed -n 's|^[^:]*:\([0-9]\+\):.*|\1|p')"
        [[ "$ff_lineno" =~ ^[0-9]+$ ]] || continue
        flawfinder_findings_pre_filter=$((flawfinder_findings_pre_filter + 1))
        in_window=0
        while IFS= read -r added_ln; do
          delta=$(( ff_lineno - added_ln ))
          [[ $delta -lt 0 ]] && delta=$(( -delta ))
          if [[ $delta -le 3 ]]; then in_window=1; break; fi
        done <<< "$added_lines_for_file"
        [[ $in_window -eq 1 ]] || continue
        flawfinder_findings_windowed=$((flawfinder_findings_windowed + 1))
        # Extract CWE and level
        ff_cwe="$(printf '%s' "$ff_line" | grep -oE 'CWE-[0-9]+' | head -1 || true)"
        ff_level="$(printf '%s' "$ff_line" | grep -oE '\[([0-9])\]' | tr -d '[]' | head -1 || true)"
        ff_msg="$(printf '%s' "$ff_line" | sed 's/^[^:]*:[0-9]*:[0-9]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | cut -c1-120)"
        # Map level to severity
        sev="medium"
        [[ "$ff_level" -ge 4 ]] 2>/dev/null && sev="high"
        rule_id="FF-${ff_cwe:-GENERIC}-${ff_level:-3}"
        loc="${cfile}:${ff_lineno}"
        # Strip temp file path from evidence - use relative path for clean output
        ff_msg_clean="$(printf '%s' "$ff_msg" | sed "s|$tmp_dir/[^:]*:||g" | sed "s|$repo_dir/||g")"
        evidence="${rule_id}: ${cfile}:${ff_lineno}: ${ff_msg_clean}"
        risk="Flawfinder level ${ff_level:-?} (${ff_cwe:-unknown}): dangerous function or pattern detected in changed code."
        action="Review this usage carefully; prefer safer alternatives (e.g. strlcpy over strcpy, snprintf over sprintf). See https://dwheeler.com/flawfinder/ and ${ff_cwe}."
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$sev" "security" "$loc" "$evidence" "$risk" "$action" "$rule_id" "https://dwheeler.com/flawfinder/" "high" >> "$flawfinder_raw_tsv"
      done <<< "$ff_out"
    done <<< "$all_ff_files"
    if [[ -s "$flawfinder_raw_tsv" ]]; then
      flawfinder_findings_total="$(wc -l < "$flawfinder_raw_tsv" | tr -d ' ')"
    fi
  fi
fi

# Optional external static rules pass (engine selected by EXTERNAL_YAML_ENGINE): disabled by default.
# Supported engines: semgrep, gitlab_sast, datadog_custom_rules, clang_tidy, bearer, codeql
is_semgrep_config_ref() {
  local cfg="$1"
  if [[ -f "$cfg" || -d "$cfg" ]]; then
    return 0
  fi
  if [[ "$cfg" =~ ^(p/|r/|https?://) ]]; then
    return 0
  fi
  return 1
}

is_semgrep_family_engine() {
  case "${external_yaml_engine}" in
    semgrep|gitlab_sast|gitlab-sast|gitlab|gitlab_sast_passthrough|datadog|datadog_custom_rules|datadog-custom-rules)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

extract_gitlab_sast_configs_from_toml() {
  local toml="$1"
  [[ -f "$toml" ]] || return 0
  sed -n 's/^[[:space:]]*\(value\|path\)[[:space:]]*=[[:space:]]*"\([^"]\+\)".*/\2/p' "$toml"
}

external_yaml_abs_to_rel() {
  local path="$1"
  if [[ "$path" == file://* ]]; then
    path="${path#file://}"
  fi
  if [[ "$path" == "$repo_dir/"* ]]; then
    path="${path#"$repo_dir/"}"
  fi
  path="${path#./}"
  printf '%s' "$path"
}

external_yaml_emit_finding() {
  local cfile="$1"
  local line="$2"
  local rule_id="$3"
  local msg="$4"
  local sev_text="$5"
  local meta_note="$6"
  local reference="$7"
  [[ "$line" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$cfile" ]] || return 0

  external_yaml_findings_pre_filter=$((external_yaml_findings_pre_filter + 1))
  local added_lines_for_file
  added_lines_for_file="$(awk -F'\t' -v f="$cfile" '$1==f && $2~/^[0-9]+$/ {print $2}' "$added_lines_tsv")"
  [[ -n "$added_lines_for_file" ]] || return 0

  local in_window=0
  local added_ln
  while IFS= read -r added_ln; do
    local delta=$(( line - added_ln ))
    [[ $delta -lt 0 ]] && delta=$(( -delta ))
    if [[ $delta -le $external_yaml_window ]]; then
      in_window=1
      break
    fi
  done <<< "$added_lines_for_file"
  [[ "$in_window" -eq 1 ]] || return 0
  external_yaml_findings_windowed=$((external_yaml_findings_windowed + 1))

  local sev="medium"
  if printf '%s' "$sev_text" | grep -Eqi 'error|high|critical'; then
    sev="high"
  fi
  local msg_clean
  msg_clean="$(printf '%s' "$msg" | sed 's/[[:space:]]\+/ /g' | cut -c1-160)"
  local loc="${cfile}:${line}"
  local evidence="${rule_id}: ${msg_clean}"
  local risk="External analyzer rule (${meta_note:-external}) matched changed code."
  local action="Validate the pattern in context and fix or explicitly suppress with rationale if intentional."
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sev" "security" "$loc" "$evidence" "$risk" "$action" "$rule_id" "${reference:-external}" "high" >> "$external_yaml_raw_tsv"
}

external_yaml_semgrep_rule_prefix="SG"
external_yaml_semgrep_meta_default="external-yaml"
if [[ "${external_yaml_engine}" == "gitlab_sast" || "${external_yaml_engine}" == "gitlab-sast" || "${external_yaml_engine}" == "gitlab" || "${external_yaml_engine}" == "gitlab_sast_passthrough" ]]; then
  external_yaml_semgrep_rule_prefix="GLS"
  external_yaml_semgrep_meta_default="gitlab-sast"
  if [[ -n "$external_yaml_gitlab_ruleset" ]]; then
    external_yaml_config="$external_yaml_gitlab_ruleset"
    external_yaml_config_display="$external_yaml_gitlab_ruleset"
    external_yaml_config_list=()
    IFS=',' read -r -a _gitlab_cfg_parts <<< "$external_yaml_gitlab_ruleset"
    for _cfg in "${_gitlab_cfg_parts[@]}"; do
      _cfg_trimmed="$(printf '%s' "$_cfg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$_cfg_trimmed" ]] || continue
      external_yaml_config_list+=("$_cfg_trimmed")
    done
  fi
  declare -a _gitlab_resolved_cfgs=()
  for _cfg in "${external_yaml_config_list[@]}"; do
    if [[ -f "$_cfg" && "$_cfg" == *.toml ]]; then
      cfg_dir="$(cd "$(dirname "$_cfg")" && pwd)"
      extracted_any=0
      while IFS= read -r _gl_cfg; do
        _gl_cfg_trimmed="$(printf '%s' "$_gl_cfg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -n "$_gl_cfg_trimmed" ]] || continue
        if [[ "$_gl_cfg_trimmed" != /* && -f "$cfg_dir/$_gl_cfg_trimmed" ]]; then
          _gl_cfg_trimmed="$cfg_dir/$_gl_cfg_trimmed"
        fi
        _gitlab_resolved_cfgs+=("$_gl_cfg_trimmed")
        extracted_any=1
      done < <(extract_gitlab_sast_configs_from_toml "$_cfg")
      if [[ "$extracted_any" -eq 0 ]]; then
        printf 'external-yaml: gitlab ruleset had no passthrough value/path entries: %s\n' "$_cfg" >> "$external_yaml_log"
      fi
    else
      _gitlab_resolved_cfgs+=("$_cfg")
    fi
  done
  if [[ "${#_gitlab_resolved_cfgs[@]}" -gt 0 ]]; then
    external_yaml_config_list=("${_gitlab_resolved_cfgs[@]}")
    external_yaml_config_display="$(printf '%s' "${external_yaml_config_list[*]}" | tr ' ' ',')"
  fi
elif [[ "${external_yaml_engine}" == "datadog" || "${external_yaml_engine}" == "datadog_custom_rules" || "${external_yaml_engine}" == "datadog-custom-rules" ]]; then
  external_yaml_semgrep_rule_prefix="DD"
  external_yaml_semgrep_meta_default="datadog-custom"
  if [[ -n "$external_yaml_datadog_rules" ]]; then
    external_yaml_config="$external_yaml_datadog_rules"
    external_yaml_config_display="$external_yaml_datadog_rules"
    external_yaml_config_list=()
    IFS=',' read -r -a _dd_cfg_parts <<< "$external_yaml_datadog_rules"
    for _cfg in "${_dd_cfg_parts[@]}"; do
      _cfg_trimmed="$(printf '%s' "$_cfg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$_cfg_trimmed" ]] || continue
      external_yaml_config_list+=("$_cfg_trimmed")
    done
    if [[ "${#external_yaml_config_list[@]}" -gt 0 ]]; then
      external_yaml_config_display="$(printf '%s' "${external_yaml_config_list[*]}" | tr ' ' ',')"
    fi
  fi
fi

if is_semgrep_family_engine; then
  if ! command -v semgrep >/dev/null 2>&1; then
    printf 'external-yaml: semgrep not found in PATH, skipping.\n' >> "$external_yaml_log"
  else
    invalid_sg_cfg=0
    for _cfg in "${external_yaml_config_list[@]}"; do
      if ! is_semgrep_config_ref "$_cfg"; then
        printf 'external-yaml: config not found/invalid: %s\n' "$_cfg" >> "$external_yaml_log"
        invalid_sg_cfg=1
      fi
    done
    if [[ "$invalid_sg_cfg" -ne 0 ]]; then
      :
    else
      external_yaml_ran=1
      all_sg_files="$(jq -r '.[] | .filename // empty' "$files_json" 2>/dev/null | grep -E '\.(c|h|cc|cpp|cxx|hpp|hh)$' | sort -u || true)"
      declare -a semgrep_targets=()
      if [[ -n "$all_sg_files" ]]; then
        while IFS= read -r cfile; do
          [[ -n "$cfile" ]] || continue
          abs_file="$repo_dir/$cfile"
          [[ -f "$abs_file" ]] || continue
          added_lines_for_file="$(awk -F'\t' -v f="$cfile" '$1==f && $2~/^[0-9]+$/ {print $2}' "$added_lines_tsv")"
          [[ -n "$added_lines_for_file" ]] || continue
          semgrep_targets+=("$abs_file")
        done <<< "$all_sg_files"
      fi
      if [[ "${#semgrep_targets[@]}" -gt 0 ]]; then
        semgrep_cmd=(
          semgrep scan --quiet --json
          --timeout "$external_yaml_semgrep_rule_timeout_sec"
          --timeout-threshold "$external_yaml_semgrep_timeout_threshold"
          --interfile-timeout 0
          --max-target-bytes "$external_yaml_semgrep_max_target_bytes"
          --jobs "$external_yaml_semgrep_jobs"
        )
        for _cfg in "${external_yaml_config_list[@]}"; do
          semgrep_cmd+=(--config "$_cfg")
        done
        semgrep_cmd+=("${semgrep_targets[@]}")

        sg_json=""
        sg_rc=0
        set +e
        if command -v timeout >/dev/null 2>&1; then
          sg_json="$(SEMGREP_SEND_METRICS=off timeout --signal=TERM "${external_yaml_semgrep_scan_timeout_sec}s" "${semgrep_cmd[@]}" 2>>"$external_yaml_log")"
          sg_rc=$?
        else
          sg_json="$(SEMGREP_SEND_METRICS=off "${semgrep_cmd[@]}" 2>>"$external_yaml_log")"
          sg_rc=$?
        fi
        set -e

        if [[ "$sg_rc" -eq 124 || "$sg_rc" -eq 137 ]]; then
          printf 'external-yaml: semgrep timed out (%ss) while scanning %s files.\n' \
            "$external_yaml_semgrep_scan_timeout_sec" "${#semgrep_targets[@]}" >> "$external_yaml_log"
        elif [[ "$sg_rc" -ne 0 && "$sg_rc" -ne 1 ]]; then
          printf 'external-yaml: semgrep exited rc=%s while scanning %s files.\n' \
            "$sg_rc" "${#semgrep_targets[@]}" >> "$external_yaml_log"
        fi

        if [[ -n "$sg_json" ]] && printf '%s' "$sg_json" | jq -e '.results? != null' >/dev/null 2>&1; then
          while IFS=$'\t' read -r _sg_path sg_line sg_rule sg_msg sg_sev sg_cwe sg_owasp; do
            [[ "$sg_line" =~ ^[0-9]+$ ]] || continue
            external_yaml_findings_pre_filter=$((external_yaml_findings_pre_filter + 1))

            cfile="$_sg_path"
            if [[ "$cfile" == "$repo_dir/"* ]]; then
              cfile="${cfile#"$repo_dir/"}"
            fi
            cfile="${cfile#./}"
            [[ -n "$cfile" ]] || continue
            added_lines_for_file="$(awk -F'\t' -v f="$cfile" '$1==f && $2~/^[0-9]+$/ {print $2}' "$added_lines_tsv")"
            [[ -n "$added_lines_for_file" ]] || continue

            in_window=0
            while IFS= read -r added_ln; do
              delta=$(( sg_line - added_ln ))
              [[ $delta -lt 0 ]] && delta=$(( -delta ))
              if [[ $delta -le $external_yaml_window ]]; then
                in_window=1
                break
              fi
            done <<< "$added_lines_for_file"
            [[ $in_window -eq 1 ]] || continue
            external_yaml_findings_windowed=$((external_yaml_findings_windowed + 1))

            sev="medium"
            if printf '%s' "$sg_sev" | grep -Eqi 'error'; then
              sev="high"
            fi
            rid_clean="$(printf '%s' "$sg_rule" | tr '/: .@' '-' | tr -cd 'A-Za-z0-9_-')"
            rule_id="${external_yaml_semgrep_rule_prefix}-${rid_clean:-RULE}"
            meta_note=""
            if [[ -n "$sg_cwe" ]]; then
              meta_note="$sg_cwe"
            elif [[ -n "$sg_owasp" ]]; then
              meta_note="$sg_owasp"
            else
              meta_note="$external_yaml_semgrep_meta_default"
            fi
            sg_msg_clean="$(printf '%s' "$sg_msg" | sed 's/[[:space:]]\+/ /g' | cut -c1-160)"
            loc="${cfile}:${sg_line}"
            evidence="${rule_id}: ${sg_msg_clean}"
            risk="External YAML rule (${meta_note}) matched changed C/C++ code."
            action="Validate the pattern in context and fix or explicitly suppress with rationale if intentional."
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$sev" "security" "$loc" "$evidence" "$risk" "$action" "$rule_id" "$external_yaml_config_display" "high" >> "$external_yaml_raw_tsv"
          done < <(printf '%s' "$sg_json" | jq -r '
            .results[]? |
            [
              (.path // ""),
              ((.start.line // 0) | tostring),
              (.check_id // "rule"),
              ((.extra.message // "") | gsub("[\\r\\n\\t]+"; " ")),
              (.extra.severity // "WARNING"),
              (
                if ((.extra.metadata.cwe? // null) | type) == "array" then
                  (.extra.metadata.cwe[0] // "")
                else
                  (.extra.metadata.cwe // .extra.metadata.cwe_id // "")
                end
              ),
              (
                if ((.extra.metadata.owasp? // null) | type) == "array" then
                  (.extra.metadata.owasp[0] // "")
                else
                  (.extra.metadata.owasp // "")
                end
              )
            ] | @tsv
          ' 2>>"$external_yaml_log" || true)
        fi
        if [[ -s "$external_yaml_raw_tsv" ]]; then
          external_yaml_findings_total="$(wc -l < "$external_yaml_raw_tsv" | tr -d ' ')"
        fi
      fi
    fi
  fi
fi

if [[ "${external_yaml_engine}" == "clang_tidy" || "${external_yaml_engine}" == "clang-tidy" ]]; then
  if ! command -v clang-tidy >/dev/null 2>&1; then
    printf 'external-yaml: clang-tidy not found in PATH, skipping.\n' >> "$external_yaml_log"
  else
    external_yaml_ran=1
    all_ct_files="$(jq -r '.[] | .filename // empty' "$files_json" 2>/dev/null | grep -E '\.(c|h|cc|cpp|cxx|hpp|hh)$' | sort -u || true)"
    if [[ -n "$all_ct_files" ]]; then
      while IFS= read -r cfile; do
        [[ -n "$cfile" ]] || continue
        abs_file="$repo_dir/$cfile"
        [[ -f "$abs_file" ]] || continue
        added_lines_for_file="$(awk -F'\t' -v f="$cfile" '$1==f && $2~/^[0-9]+$/ {print $2}' "$added_lines_tsv")"
        [[ -n "$added_lines_for_file" ]] || continue

        ct_cmd=(clang-tidy --quiet --checks "$external_yaml_clang_tidy_checks" "$abs_file" --)
        ct_out=""
        ct_rc=0
        set +e
        if command -v timeout >/dev/null 2>&1; then
          ct_out="$(timeout --signal=TERM "${external_yaml_clang_tidy_timeout_sec}s" "${ct_cmd[@]}" 2>&1)"
          ct_rc=$?
        else
          ct_out="$("${ct_cmd[@]}" 2>&1)"
          ct_rc=$?
        fi
        set -e
        [[ -n "$ct_out" ]] && printf '%s\n' "$ct_out" >> "$external_yaml_log"
        if [[ "$ct_rc" -eq 124 || "$ct_rc" -eq 137 ]]; then
          printf 'external-yaml: clang-tidy timed out (%ss) on %s.\n' \
            "$external_yaml_clang_tidy_timeout_sec" "$cfile" >> "$external_yaml_log"
        fi

        while IFS=$'\t' read -r ct_line ct_check ct_msg ct_sev; do
          [[ "$ct_line" =~ ^[0-9]+$ ]] || continue
          rid_clean="$(printf '%s' "$ct_check" | tr '/: .@' '-' | tr -cd 'A-Za-z0-9_-')"
          rule_id="CT-${rid_clean:-RULE}"
          external_yaml_emit_finding "$cfile" "$ct_line" "$rule_id" "$ct_msg" "$ct_sev" "${ct_check:-clang-tidy}" "clang-tidy"
        done < <(printf '%s\n' "$ct_out" | awk -v f="$abs_file" '
          index($0, f ":") == 1 {
            n=split($0, a, ":");
            if (n < 4) next;
            line=a[2];
            if (line !~ /^[0-9]+$/) next;
            msg=a[4];
            for (i=5; i<=n; i++) msg=msg ":" a[i];
            sub(/^[[:space:]]+/, "", msg);
            sev="warning";
            if (msg ~ /^error:/) sev="error";
            sub(/^(warning|error):[[:space:]]*/, "", msg);
            check="clang-tidy";
            if (match(msg, /\[[^][]+\][[:space:]]*$/)) {
              check=substr(msg, RSTART+1, RLENGTH-2);
              msg=substr(msg, 1, RSTART-1);
              sub(/[[:space:]]+$/, "", msg);
            }
            gsub(/\t/, " ", msg);
            print line "\t" check "\t" msg "\t" sev;
          }
        ')
      done <<< "$all_ct_files"
    fi
    if [[ -s "$external_yaml_raw_tsv" ]]; then
      external_yaml_findings_total="$(wc -l < "$external_yaml_raw_tsv" | tr -d ' ')"
    fi
  fi
fi

if [[ "${external_yaml_engine}" == "bearer" ]]; then
  if ! command -v bearer >/dev/null 2>&1; then
    printf 'external-yaml: bearer not found in PATH, skipping.\n' >> "$external_yaml_log"
  else
    external_yaml_ran=1
    all_bearer_files="$(jq -r '.[] | .filename // empty' "$files_json" 2>/dev/null | grep -E '\.(c|h|cc|cpp|cxx|hpp|hh|go|py|java|js|ts|rb|php)$' | sort -u || true)"
    if [[ -n "$all_bearer_files" ]]; then
      while IFS= read -r cfile; do
        [[ -n "$cfile" ]] || continue
        abs_file="$repo_dir/$cfile"
        [[ -f "$abs_file" ]] || continue
        added_lines_for_file="$(awk -F'\t' -v f="$cfile" '$1==f && $2~/^[0-9]+$/ {print $2}' "$added_lines_tsv")"
        [[ -n "$added_lines_for_file" ]] || continue

        bearer_cmd=(bearer scan --quiet --format json --report security --scanner sast --exit-code 0 "$abs_file")
        if [[ "${#external_yaml_config_list[@]}" -gt 0 ]]; then
          for _cfg in "${external_yaml_config_list[@]}"; do
            [[ -d "$_cfg" ]] && bearer_cmd+=(--external-rule-dir "$_cfg")
          done
        fi

        br_json=""
        br_rc=0
        set +e
        if command -v timeout >/dev/null 2>&1; then
          br_json="$(timeout --signal=TERM "${external_yaml_bearer_timeout_sec}s" "${bearer_cmd[@]}" 2>>"$external_yaml_log")"
          br_rc=$?
        else
          br_json="$("${bearer_cmd[@]}" 2>>"$external_yaml_log")"
          br_rc=$?
        fi
        set -e

        if [[ "$br_rc" -eq 124 || "$br_rc" -eq 137 ]]; then
          printf 'external-yaml: bearer timed out (%ss) on %s.\n' \
            "$external_yaml_bearer_timeout_sec" "$cfile" >> "$external_yaml_log"
        fi
        [[ -n "$br_json" ]] || continue

        while IFS=$'\t' read -r br_path br_line br_rule br_msg br_sev br_cwe; do
          [[ "$br_line" =~ ^[0-9]+$ ]] || continue
          rel_path="$(external_yaml_abs_to_rel "$br_path")"
          [[ -n "$rel_path" ]] || rel_path="$cfile"
          rid_clean="$(printf '%s' "$br_rule" | tr '/: .@' '-' | tr -cd 'A-Za-z0-9_-')"
          rule_id="BR-${rid_clean:-RULE}"
          meta="${br_cwe:-bearer}"
          external_yaml_emit_finding "$rel_path" "$br_line" "$rule_id" "$br_msg" "$br_sev" "$meta" "bearer"
        done < <(printf '%s' "$br_json" | jq -r '
          (
            .findings[]?,
            .results[]?,
            .issues[]?,
            .security[]?,
            .vulnerabilities[]?
          ) |
          [
            (.location.path // .path // ""),
            ((.location.start_line // .location.start.line // .location.line // .line // 0) | tostring),
            (.id // .rule_id // .check_id // .title // "rule"),
            ((.description // .message // .title // .name // "") | gsub("[\\r\\n\\t]+"; " ")),
            (.severity // .level // "WARNING"),
            (.cwe // .metadata.cwe // "")
          ] | @tsv
        ' 2>>"$external_yaml_log" || true)
      done <<< "$all_bearer_files"
    fi
    if [[ -s "$external_yaml_raw_tsv" ]]; then
      external_yaml_findings_total="$(wc -l < "$external_yaml_raw_tsv" | tr -d ' ')"
    fi
  fi
fi

if [[ "${external_yaml_engine}" == "codeql" ]]; then
  if ! command -v codeql >/dev/null 2>&1; then
    printf 'external-yaml: codeql not found in PATH, skipping.\n' >> "$external_yaml_log"
  elif [[ -z "$external_yaml_codeql_db" || ! -d "$external_yaml_codeql_db" ]]; then
    printf 'external-yaml: codeql DB not set or missing (EXTERNAL_CODEQL_DB), skipping.\n' >> "$external_yaml_log"
  else
    external_yaml_ran=1
    codeql_findings_tsv="$tmp_dir/codeql_findings.tsv"
    : > "$codeql_findings_tsv"
    codeql_cache_hit=0
    codeql_cache_file=""
    if [[ "$external_yaml_codeql_cache_disable" != "1" ]]; then
      mkdir -p "$external_yaml_codeql_cache_dir" >/dev/null 2>&1 || true
      codeql_db_sig="$(stat -c '%Y:%s' "$external_yaml_codeql_db/codeql-database.yml" 2>/dev/null || stat -c '%Y:%s' "$external_yaml_codeql_db" 2>/dev/null || echo "unknown")"
      codeql_cache_key="$(printf '%s' "${external_yaml_codeql_db}|${external_yaml_codeql_query_suite}|${codeql_db_sig}" | sha256sum | awk '{print $1}')"
      codeql_cache_file="$external_yaml_codeql_cache_dir/${codeql_cache_key}.tsv"
      if [[ -s "$codeql_cache_file" ]]; then
        codeql_cache_hit=1
        cp "$codeql_cache_file" "$codeql_findings_tsv"
        printf 'external-yaml: codeql cache hit (%s).\n' "$codeql_cache_file" >> "$external_yaml_log"
      fi
    fi

    if [[ "$codeql_cache_hit" -ne 1 ]]; then
      [[ "$external_yaml_codeql_cache_disable" == "1" ]] && printf 'external-yaml: codeql cache disabled.\n' >> "$external_yaml_log"
      sarif_out="$tmp_dir/codeql_findings.sarif"
      cq_cmd=(
        codeql database analyze
        --format=sarifv2.1.0
        --output "$sarif_out"
        --no-print-diagnostics-summary
        --no-print-metrics-summary
        --
        "$external_yaml_codeql_db"
        "$external_yaml_codeql_query_suite"
      )
      cq_rc=0
      set +e
      if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM "${external_yaml_codeql_timeout_sec}s" "${cq_cmd[@]}" >>"$external_yaml_log" 2>&1
        cq_rc=$?
      else
        "${cq_cmd[@]}" >>"$external_yaml_log" 2>&1
        cq_rc=$?
      fi
      set -e

      if [[ "$cq_rc" -eq 124 || "$cq_rc" -eq 137 ]]; then
        printf 'external-yaml: codeql timed out (%ss).\n' "$external_yaml_codeql_timeout_sec" >> "$external_yaml_log"
      elif [[ "$cq_rc" -ne 0 ]]; then
        printf 'external-yaml: codeql exited rc=%s.\n' "$cq_rc" >> "$external_yaml_log"
      fi

      if [[ -f "$sarif_out" ]]; then
        jq -r '
          .runs[]?.results[]? |
          [
            (.locations[0].physicalLocation.artifactLocation.uri // ""),
            ((.locations[0].physicalLocation.region.startLine // 0) | tostring),
            (.ruleId // "rule"),
            ((.message.text // "") | gsub("[\\r\\n\\t]+"; " ")),
            (.level // "warning"),
            (
              (
                .properties.tags[]? // ""
              ) | select(test("CWE-"; "i"))
            )
          ] | @tsv
        ' "$sarif_out" > "$codeql_findings_tsv" 2>>"$external_yaml_log" || true
      fi
      if [[ -n "$codeql_cache_file" && -s "$codeql_findings_tsv" ]]; then
        cp "$codeql_findings_tsv" "$codeql_cache_file" 2>/dev/null || true
        printf 'external-yaml: codeql cache write (%s).\n' "$codeql_cache_file" >> "$external_yaml_log"
      fi
    fi

    if [[ -s "$codeql_findings_tsv" ]]; then
      while IFS=$'\t' read -r cq_path cq_line cq_rule cq_msg cq_sev cq_cwe; do
        [[ "$cq_line" =~ ^[0-9]+$ ]] || continue
        rel_path="$(external_yaml_abs_to_rel "$cq_path")"
        [[ -n "$rel_path" ]] || continue
        if [[ -s "$pr_files_txt" ]] && ! grep -Fqx -- "$rel_path" "$pr_files_txt"; then
          continue
        fi
        rid_clean="$(printf '%s' "$cq_rule" | tr '/: .@' '-' | tr -cd 'A-Za-z0-9_-')"
        rule_id="CQ-${rid_clean:-RULE}"
        meta="${cq_cwe:-codeql}"
        external_yaml_emit_finding "$rel_path" "$cq_line" "$rule_id" "$cq_msg" "$cq_sev" "$meta" "${external_yaml_codeql_query_suite}"
      done < "$codeql_findings_tsv"
    fi
    if [[ -s "$external_yaml_raw_tsv" ]]; then
      external_yaml_findings_total="$(wc -l < "$external_yaml_raw_tsv" | tr -d ' ')"
    fi
  fi
fi

while IFS=$'\t' read -r cid path line reviewer body; do
  loc="${path}:${line}"
  [[ -z "$path" ]] && loc="review-comment"
  if [[ "$body" == *"?"* ]]; then
    printf -- '- Comment `%s` (%s): %s\n' "$cid" "$loc" "$body" >> "$open_questions_md"
  fi
  printf -- '- `%s` %s (%s): %s\n' "$cid" "$reviewer" "$loc" "$body" >> "$external_notes_md"
done < <(jq -r '.[] | select((.in_reply_to_id // "") == "") | [(.id|tostring), (.path // ""), ((.line // .original_line // "")|tostring), (.user.login // ""), ((.body // "")|gsub("\\n";" "))] | @tsv' "$review_comments_json")

emit_group() {
  local title="$1"
  current_topic_group_enabled=1
  if [[ "$cross_ecosystem_mode" == "repo-aware" && "$style_family_detected" != "generic" ]]; then
    current_topic_group_enabled=0
    case "$style_family_detected" in
      edk2|linux|uboot)
        [[ "$title" == "Linux Kernel Submission Checklist" || \
           "$title" == "Google Code Review Standard" || \
           "$title" == "OWASP Secure Code Review" ]] && current_topic_group_enabled=1
        ;;
      qemu)
        [[ "$title" == "QEMU Patch Workflow Expectations" || \
           "$title" == "Linux Kernel Submission Checklist" || \
           "$title" == "Google Code Review Standard" || \
           "$title" == "OWASP Secure Code Review" ]] && current_topic_group_enabled=1
        ;;
      *)
        current_topic_group_enabled=1
        ;;
    esac
  fi

  if [[ "$current_topic_group_enabled" -eq 1 ]]; then
    echo "### ${title}" >> "$topic_tasks_md"
  else
    omitted_topic_groups=$((omitted_topic_groups + 1))
  fi
}

emit_task() {
  local status="$1"
  local text="$2"
  if [[ "$current_topic_group_enabled" -eq 1 ]]; then
    echo "- [${status}] ${text}" >> "$topic_tasks_md"
  fi
}

task_status_bool() {
  local cond="$1"
  if [[ "$cond" == "true" ]]; then
    printf 'pass'
  else
    printf 'attention'
  fi
}

task_status_not_bool() {
  local cond="$1"
  if [[ "$cond" == "true" ]]; then
    printf 'attention'
  else
    printf 'pass'
  fi
}

emit_matrix_group() {
  local title="$1"
  current_matrix_group_enabled=1
  if [[ "$cross_ecosystem_mode" == "repo-aware" && "$style_family_detected" != "generic" ]]; then
    current_matrix_group_enabled=0
    case "$style_family_detected" in
      edk2|linux|uboot)
        [[ "$title" == "Linux Coding-Style Rule Matrix" || \
           "$title" == "Google Reviewer Rule Matrix" || \
           "$title" == "OWASP Rule Matrix" ]] && current_matrix_group_enabled=1
        ;;
      qemu)
        [[ "$title" == "QEMU Rule Matrix" || \
           "$title" == "Linux Coding-Style Rule Matrix" || \
           "$title" == "Google Reviewer Rule Matrix" || \
           "$title" == "OWASP Rule Matrix" ]] && current_matrix_group_enabled=1
        ;;
      *)
        current_matrix_group_enabled=1
        ;;
    esac
  fi

  if [[ "$current_matrix_group_enabled" -eq 1 ]]; then
    {
      echo "### ${title}"
      echo "| Rule ID | Rule | Status | Evidence/Notes | Source |"
      echo "| --- | --- | --- | --- | --- |"
    } >> "$rule_matrix_md"
  else
    omitted_matrix_groups=$((omitted_matrix_groups + 1))
  fi
}

emit_matrix_rule() {
  local rule_id="$1"
  local rule_text="$2"
  local status="$3"
  local note="$4"
  local source_link="$5"
  if [[ "$current_matrix_group_enabled" -eq 1 ]]; then
    printf '| `%s` | %s | `%s` | %s | %s |\n' "$rule_id" "$rule_text" "$status" "$note" "$source_link" >> "$rule_matrix_md"
  fi
}

map_checkpatch_rule() {
  local msg="$1"
  CP_RULE_ID="LNX-CS-GENERAL"
  CP_RULE_LINK="https://www.kernel.org/doc/html/v4.17/process/coding-style.html"
  if printf '%s' "$msg" | grep -Eqi 'indent|spaces at the start|tab'; then
    CP_RULE_ID="LNX-CS-1"
    CP_RULE_LINK="https://www.kernel.org/doc/html/v4.17/process/coding-style.html#indentation"
  elif printf '%s' "$msg" | grep -Eqi 'line over|long line'; then
    CP_RULE_ID="LNX-CS-2"
    CP_RULE_LINK="https://www.kernel.org/doc/html/v4.17/process/coding-style.html#breaking-long-lines-and-strings"
  elif printf '%s' "$msg" | grep -Eqi 'brace|spacing'; then
    CP_RULE_ID="LNX-CS-3"
    CP_RULE_LINK="https://www.kernel.org/doc/html/v4.17/process/coding-style.html#placing-braces-and-spaces"
  elif printf '%s' "$msg" | grep -Eqi 'spdx'; then
    CP_RULE_ID="LNX-SUBMIT-DOC"
    CP_RULE_LINK="https://www.kernel.org/doc/html/latest/process/submitting-patches.html"
  fi
}

detect_checkpatch_cmd() {
  return 1
}

checkpatch_used=""
checkpatch_source="none"
checkpatch_decision="auto"
checkpatch_status="SKIPPED"
checkpatch_mode="not-run"
checkpatch_errors=0
checkpatch_warnings=0
checkpatch_summary_line=""
style_family_detected="$style_family"
checkpatch_inline_total=0
checkpatch_inline_included=0
clang_semantic_available=0
clang_semantic_ran=0
clang_semantic_diag_total=0
clang_semantic_inline_included=0
clang_semantic_suppressed=0
current_topic_group_enabled=1
current_matrix_group_enabled=1
omitted_topic_groups=0
omitted_matrix_groups=0
detect_style_family() {
  local root="$1"
  local review_text=""

  if [[ "$style_family" != "auto" ]]; then
    printf '%s' "$style_family"
    return 0
  fi

  review_text="$(jq -r '[.[]?.body // ""] | join(" ") | ascii_downcase' "$review_comments_json" 2>/dev/null || true)"
  if [[ "$review_text" == *"patchcheck.py"* || "$review_text" == *"edk2"* ]]; then
    printf 'edk2'
    return 0
  fi
  if [[ "$review_text" == *"linux/scripts/checkpatch.pl"* || "$review_text" == *"checkpatch.pl"* ]]; then
    printf 'linux'
    return 0
  fi

  if [[ -f "$root/BaseTools/Scripts/PatchCheck.py" || -f "$root/Maintainers.txt" ]] || \
     jq -e 'any(.[]; (.filename|test("\\.(dsc|dec|inf)$|^BaseTools/|^MdePkg/|^MdeModulePkg/")))' "$files_json" >/dev/null 2>&1; then
    printf 'edk2'
    return 0
  fi

  if [[ -f "$root/docs/devel/submitting-a-patch.rst" || -f "$root/meson.build" ]] || \
     jq -e 'any(.[]; (.filename|test("^docs/devel/|^hw/|^target/|^qapi/|^softmmu/")))' "$files_json" >/dev/null 2>&1; then
    printf 'qemu'
    return 0
  fi

  if [[ -f "$root/doc/develop/checkpatch.rst" || -d "$root/tools/patman" ]] || \
     jq -e 'any(.[]; (.filename|test("^arch/|^board/|^configs/|^drivers/|^include/configs/")))' "$files_json" >/dev/null 2>&1; then
    printf 'uboot'
    return 0
  fi

  if [[ -f "$root/Documentation/process/submitting-patches.rst" || -d "$root/kernel" ]] || \
     jq -e 'any(.[]; (.filename|test("^kernel/|^mm/|^fs/|^net/|^drivers/|^arch/|^include/linux/")))' "$files_json" >/dev/null 2>&1; then
    printf 'linux'
    return 0
  fi

  printf 'generic'
}

resolve_local_checker_cmd() {
  local root="$1"
  local c=""

  if [[ -x "$root/BaseTools/Scripts/PatchCheck.py" ]]; then
    c="python3 $root/BaseTools/Scripts/PatchCheck.py --oneline"
    printf '%s' "$c"
    return 0
  fi
  if [[ -f "$root/BaseTools/Scripts/PatchCheck.py" ]]; then
    c="python3 $root/BaseTools/Scripts/PatchCheck.py --oneline"
    printf '%s' "$c"
    return 0
  fi
  if [[ -x "$root/scripts/checkpatch.pl" ]]; then
    c="$root/scripts/checkpatch.pl --no-tree"
    printf '%s' "$c"
    return 0
  fi
  if [[ -f "$root/scripts/checkpatch.pl" ]]; then
    c="perl $root/scripts/checkpatch.pl --no-tree"
    printf '%s' "$c"
    return 0
  fi

  return 1
}

fetch_checker_cmd() {
  local family="$1"
  local tools_dir="$tmp_dir/tools"
  mkdir -p "$tools_dir"

  if [[ "$family" == "edk2" ]]; then
    local dst="$tools_dir/PatchCheck.py"
    if curl -fsSL "https://raw.githubusercontent.com/tianocore/edk2/master/BaseTools/Scripts/PatchCheck.py" -o "$dst"; then
      chmod +x "$dst" || true
      printf 'python3 %s --oneline' "$dst"
      return 0
    fi
  else
    local dst="$tools_dir/checkpatch.pl"
    if curl -fsSL "https://raw.githubusercontent.com/torvalds/linux/master/scripts/checkpatch.pl" -o "$dst"; then
      chmod +x "$dst" || true
      printf 'perl %s --no-tree' "$dst"
      return 0
    fi
  fi

  return 1
}

extract_checkpatch_inline_candidates() {
  local log_file="$1"
  awk '
  BEGIN { sev=""; msg="" }
  /^ERROR([[:space:]]*[:-])[[:space:]]*/ {
    sev="high"
    msg=$0
    sub(/^ERROR([[:space:]]*[:-])[[:space:]]*/, "", msg)
    next
  }
  /^WARNING([[:space:]]*[:-])[[:space:]]*/ {
    sev="medium"
    msg=$0
    sub(/^WARNING([[:space:]]*[:-])[[:space:]]*/, "", msg)
    next
  }
  {
    if (match($0, /^#[0-9]+:[[:space:]]+FILE:[[:space:]]+([^:]+):([0-9]+):/, m)) {
      if (sev != "" && msg != "") {
        printf "%s\t%s\t%s\t%s\n", sev, m[1], m[2], msg
      }
    }
  }' "$log_file"
}

resolve_bug_scorer_cmd() {
  local model_dir=""
  local bundle_dir=""

  if [[ -n "$bug_scorer_cmd" ]]; then
    printf '%s' "$bug_scorer_cmd"
    return 0
  fi

  if [[ -n "$bug_model_path" && -f "$bug_model_path" ]]; then
    model_dir="$(dirname "$bug_model_path")"
    bundle_dir="$(dirname "$model_dir")"
    if [[ -x "$bundle_dir/runtime/install.sh" ]]; then
      printf '%s' "$bundle_dir/runtime/install.sh --score-pairwise"
      return 0
    fi
  fi

  if [[ -n "${BUG_SCORER_CMD:-}" ]]; then
    printf '%s' "${BUG_SCORER_CMD}"
    return 0
  fi

  if [[ -x "/local/mnt/workspace/git/ml-bug-feature-extractor/install.sh" ]]; then
    printf '%s' "/local/mnt/workspace/git/ml-bug-feature-extractor/install.sh --score-pairwise"
    return 0
  fi

  if [[ -x "$HOME/git/ml-bug-feature-extractor/install.sh" ]]; then
    printf '%s' "$HOME/git/ml-bug-feature-extractor/install.sh --score-pairwise"
    return 0
  fi

  return 1
}

run_bug_model_signal() {
  local resolved_cmd=""
  local model_raw=""
  local model_json_payload=""
  local single_commit=""
  local action_text=""
  local location_text="model-scorer"
  local severity="medium"
  local predicted_flag="false"
  local scorer_args=()

  if [[ -z "$bug_model_path" ]]; then
    resolve_bug_model_defaults || true
  fi

  if [[ -z "$bug_model_path" ]]; then
    bug_model_status="disabled"
    return 0
  fi

  if [[ ! -f "$bug_model_path" ]]; then
    bug_model_status="model-not-found"
    return 0
  fi

  resolved_cmd="$(resolve_bug_scorer_cmd || true)"
  if [[ -z "$resolved_cmd" ]]; then
    bug_model_status="scorer-not-found"
    return 0
  fi

  read -r -a scorer_args <<< "$resolved_cmd"
  if [[ "${#scorer_args[@]}" -eq 0 ]]; then
    bug_model_status="scorer-args-invalid"
    return 0
  fi

  single_commit="$(jq -r 'if length==1 then .[0].sha // "" else "" end' "$commits_json")"

  bug_model_ran=1
  if [[ -n "$single_commit" ]]; then
    model_raw="$("${scorer_args[@]}" \
      --model "$bug_model_path" \
      --repo "$repo_dir" \
      --mode head \
      --commit "$single_commit" \
      --binary-threshold "$bug_binary_threshold" \
      --family-threshold "$bug_family_threshold" \
      --hunk-threshold "$bug_hunk_threshold" \
      --topk-hunks "$bug_topk_hunks" \
      --json 2>>"$kernel_vuln_log" || true)"
  else
    model_raw="$("${scorer_args[@]}" \
      --model "$bug_model_path" \
      --repo "$repo_dir" \
      --mode range \
      --range "$base_ref..$head_ref" \
      --binary-threshold "$bug_binary_threshold" \
      --family-threshold "$bug_family_threshold" \
      --hunk-threshold "$bug_hunk_threshold" \
      --topk-hunks "$bug_topk_hunks" \
      --json 2>>"$kernel_vuln_log" || true)"
  fi

  model_json_payload="$(printf '%s\n' "$model_raw" | sed -n '/^{/,$p')"
  if [[ -z "$model_json_payload" ]]; then
    bug_model_status="scorer-output-empty"
    return 0
  fi

  printf '%s\n' "$model_json_payload" > "$bug_model_json"
  if ! jq -e . "$bug_model_json" >/dev/null 2>&1; then
    bug_model_status="scorer-output-invalid-json"
    return 0
  fi

  bug_model_status="ok"
  bug_model_risk_score="$(jq -r '.bug_risk_score // 0' "$bug_model_json")"
  bug_model_review_mode="$(jq -r '.review_mode // ""' "$bug_model_json")"
  bug_model_family="$(jq -r '.predicted_bug_family // ""' "$bug_model_json")"
  bug_model_family_score="$(jq -r '.predicted_bug_family_score // 0' "$bug_model_json")"
  bug_model_best_hunk_score="$(jq -r '.best_hunk_score // 0' "$bug_model_json")"
  bug_model_hunk_file="$(jq -r '.hunks_topk[0].file // ""' "$bug_model_json")"
  bug_model_hunk_line="$(jq -r '.hunks_topk[0].line_hint // .hunks_topk[0].line_start // ""' "$bug_model_json")"
  bug_model_memory_used="$(jq -r '.memory_used // false' "$bug_model_json")"
  predicted_flag="$(jq -r '.predicted_bug_introducing // false' "$bug_model_json")"
  action_text="$(jq -r '.review_comments[0].detail // ""' "$bug_model_json")"
  if [[ -z "$action_text" ]]; then
    action_text="Run focused manual validation on the top-ranked hunk and confirm bug-family-specific invariants before approval."
  fi

  if [[ -n "$bug_model_hunk_file" && "$bug_model_hunk_line" =~ ^[0-9]+$ ]]; then
    location_text="${bug_model_hunk_file}:${bug_model_hunk_line}"
  fi

  if [[ "$bug_model_review_mode" == "actual-bug" && -n "$bug_model_family" ]]; then
    severity="high"
    add_finding "$severity" "correctness" "$location_text" \
      "Model-assisted detector predicts ${bug_model_family} (risk=${bug_model_risk_score}, family=${bug_model_family_score}, hunk=${bug_model_best_hunk_score}, mode=${bug_model_review_mode}, memory_used=${bug_model_memory_used})." \
      "Likely ${bug_model_family} defect in changed code path; merge without targeted validation may ship a latent vulnerability/regression." \
      "$action_text" \
      "ML-PAIRWISE-DETECTOR" "https://github.com/slingappa/ml-bug-feature-extractor"
  elif [[ "$bug_model_review_mode" == "actual-bug-lite" && -n "$bug_model_family" ]]; then
    severity="high"
    add_finding "$severity" "correctness" "$location_text" \
      "Model-assisted detector flagged ${bug_model_family} via lite gates (risk=${bug_model_risk_score}, family=${bug_model_family_score}, hunk=${bug_model_best_hunk_score}, mode=${bug_model_review_mode}, memory_used=${bug_model_memory_used})." \
      "Likely ${bug_model_family} defect in changed code path; treat as high-priority manual validation even though strict family gate did not pass." \
      "$action_text" \
      "ML-PAIRWISE-DETECTOR" "https://github.com/slingappa/ml-bug-feature-extractor"
  elif [[ "$predicted_flag" == "true" ]]; then
    if [[ "$location_text" != "model-scorer" ]] && float_ge "$bug_model_best_hunk_score" "$bug_guarded_risk_min_hunk"; then
      :
    else
      location_text="model-scorer"
    fi
    add_finding "$severity" "correctness" "$location_text" \
      "Model-assisted detector raised risk signal (risk=${bug_model_risk_score}, family=${bug_model_family:-unknown}, family_score=${bug_model_family_score}, mode=${bug_model_review_mode})." \
      "Patch appears bug-prone but bug-family/location confidence did not pass full gates." \
      "$action_text" \
      "ML-PAIRWISE-RISK" "https://github.com/slingappa/ml-bug-feature-extractor"
  fi
}

style_family_detected="$(detect_style_family "$repo_dir")"

if [[ -z "$checkpatch_cmd" ]]; then
  checkpatch_cmd="$(resolve_local_checker_cmd "$repo_dir" || true)"
  if [[ -n "$checkpatch_cmd" ]]; then
    checkpatch_source="local"
    checkpatch_decision="repo-local checker"
  elif [[ "$fetch_checkpatch" -eq 1 ]]; then
    if [[ "$style_family_detected" == "generic" ]]; then
      checkpatch_decision="ambiguous family; user hint preferred"
    else
      checkpatch_cmd="$(fetch_checker_cmd "$style_family_detected" || true)"
      checkpatch_decision="fetched checker for family ${style_family_detected}"
    fi
    if [[ -n "$checkpatch_cmd" ]]; then
      checkpatch_source="fetched"
    fi
  fi
else
  checkpatch_source="user-specified"
  checkpatch_decision="explicit command from user"
fi
checkpatch_used="$checkpatch_cmd"

if [[ -n "$checkpatch_cmd" ]]; then
  patch_mailbox="$tmp_dir/series.patch"
  patch_dir="$tmp_dir/patches"
  mkdir -p "$patch_dir"
  patch_files=()

  if git -C "$repo_dir" rev-parse --verify "$base_ref" >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --verify "$head_ref" >/dev/null 2>&1; then
    git -C "$repo_dir" format-patch --stdout "${base_ref}..${head_ref}" > "$patch_mailbox" 2>>"$checkpatch_log" || true
    git -C "$repo_dir" format-patch -o "$patch_dir" "${base_ref}..${head_ref}" >>"$checkpatch_log" 2>&1 || true
    while IFS= read -r pf; do
      patch_files+=( "$pf" )
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' | sort)

    if [[ -s "$patch_mailbox" || "${#patch_files[@]}" -gt 0 ]]; then
      if [[ "$checkpatch_cmd" == *"PatchCheck.py"* ]]; then
        if [[ "${#patch_files[@]}" -gt 0 ]]; then
          checkpatch_mode="file-patch-batch"
          cp_rc=0
          eval "$checkpatch_cmd" "\"\${patch_files[@]}\"" >>"$checkpatch_log" 2>&1 || cp_rc=$?
          if [[ "$cp_rc" -eq 0 ]]; then
            checkpatch_status="PASS"
          else
            checkpatch_status="FAIL"
          fi
        else
          checkpatch_mode="no-patch-files"
          checkpatch_status="FAIL"
          echo "No patch files generated for PatchCheck.py execution." >>"$checkpatch_log"
        fi
      else
        cp_rc=0
        if [[ -s "$patch_mailbox" ]]; then
          checkpatch_mode="stdin-patch"
          eval "cat \"$patch_mailbox\" | $checkpatch_cmd -" >>"$checkpatch_log" 2>&1 || cp_rc=$?
        else
          cp_rc=1
        fi

        if [[ "$cp_rc" -eq 0 ]]; then
          checkpatch_status="PASS"
        elif [[ "${#patch_files[@]}" -gt 0 ]]; then
          cp_rc=0
          checkpatch_mode="file-patch-loop-fallback"
          for pf in "${patch_files[@]}"; do
            eval "$checkpatch_cmd" "\"$pf\"" >>"$checkpatch_log" 2>&1 || cp_rc=1
          done
          if [[ "$cp_rc" -eq 0 ]]; then
            checkpatch_status="PASS"
          else
            checkpatch_status="FAIL"
          fi
        else
          checkpatch_status="FAIL"
          checkpatch_mode="patch-generation-failed"
        fi
      fi
    else
      checkpatch_status="SKIPPED"
      checkpatch_mode="no-patch-content"
      echo "No patch content generated for ${base_ref}..${head_ref}" >>"$checkpatch_log"
    fi
  else
    checkpatch_status="SKIPPED"
    checkpatch_mode="invalid-base-or-head"
    echo "Invalid refs for checkpatch execution: ${base_ref}..${head_ref}" >>"$checkpatch_log"
  fi

  checkpatch_summary_line="$(grep -E 'total:[[:space:]]+[0-9]+ errors?,[[:space:]]+[0-9]+ warnings?' "$checkpatch_log" | tail -n1 || true)"
  if [[ -n "$checkpatch_summary_line" ]]; then
    checkpatch_errors="$(printf '%s' "$checkpatch_summary_line" | sed -E 's/.*total:[[:space:]]*([0-9]+) errors?,[[:space:]]*([0-9]+) warnings?.*/\1/')"
    checkpatch_warnings="$(printf '%s' "$checkpatch_summary_line" | sed -E 's/.*total:[[:space:]]*([0-9]+) errors?,[[:space:]]*([0-9]+) warnings?.*/\2/')"
  else
    checkpatch_errors="$(grep -Eci '^[[:space:]]*(ERROR|error)(:|[[:space:]]+-)' "$checkpatch_log" || true)"
    checkpatch_warnings="$(grep -Eci '^[[:space:]]*(WARNING|warning)(:|[[:space:]]+-)' "$checkpatch_log" || true)"
  fi

  if [[ "$checkpatch_errors" -gt 0 ]]; then
    add_finding "high" "maintainability" "checkpatch" \
      "checkpatch reported ${checkpatch_errors} errors and ${checkpatch_warnings} warnings (${checkpatch_mode})." \
      "Patch violates project lint/style gates and may fail CI or review acceptance." \
      "Resolve all checkpatch errors and rerun before requesting final review." \
      "LNX-CS-INDEX" "https://www.kernel.org/doc/html/v4.17/process/coding-style.html"
  elif [[ "$checkpatch_warnings" -gt 0 ]]; then
    add_finding "medium" "maintainability" "checkpatch" \
      "checkpatch reported ${checkpatch_errors} errors and ${checkpatch_warnings} warnings (${checkpatch_mode})." \
      "Outstanding warnings may block strict maintainers or hide style regressions." \
      "Address warnings where possible and document intentional exceptions." \
      "LNX-CS-INDEX" "https://www.kernel.org/doc/html/v4.17/process/coding-style.html"
  fi

  extract_checkpatch_inline_candidates "$checkpatch_log" | sort -u > "$checkpatch_inline_raw_tsv" || true
  if [[ -s "$checkpatch_inline_raw_tsv" ]]; then
    checkpatch_inline_total="$(wc -l < "$checkpatch_inline_raw_tsv" | tr -d ' ')"
    while IFS=$'\t' read -r sev file line msg; do
      [[ -n "$sev" && -n "$file" && -n "$line" ]] || continue
      if [[ "$checkpatch_inline_cap" -gt 0 && "$checkpatch_inline_included" -ge "$checkpatch_inline_cap" ]]; then
        continue
      fi
      map_checkpatch_rule "$msg"
      if maybe_add_proposed_comment "$sev" "maintainability" "${file}:${line}" \
        "checkpatch: ${msg}" \
        "Fix this style issue in code and rerun checkpatch before review submission." \
        "${CP_RULE_ID}" "${CP_RULE_LINK}"; then
        checkpatch_inline_included=$((checkpatch_inline_included + 1))
      fi
    done < "$checkpatch_inline_raw_tsv"
  fi
fi

# Advanced semantic checks (clang, optional): deeper signals beyond regex heuristics.
if command -v clang >/dev/null 2>&1; then
  clang_semantic_available=1
fi

if [[ "$clang_semantic_available" -eq 1 ]]; then
  jq -r '.[] | (.filename // "") | select(test("\\.c$"))' "$files_json" | sort -u > "$changed_c_files_txt"
  if [[ -s "$changed_c_files_txt" ]]; then
    clang_semantic_ran=1
    while IFS= read -r relf; do
      [[ -n "$relf" ]] || continue
      absf="$repo_dir/$relf"
      [[ -f "$absf" ]] || continue
      # Best-effort syntax diagnostics and static analyzer pass.
      clang -fsyntax-only -Wall -Wextra \
        -Wno-unused-function -Wno-unused-variable -Wno-missing-field-initializers \
        -I"$repo_dir" -I"$repo_dir/include" "$absf" >>"$clang_semantic_log" 2>&1 || true
      clang --analyze -Xanalyzer -analyzer-output=text \
        -I"$repo_dir" -I"$repo_dir/include" "$absf" >>"$clang_semantic_log" 2>&1 || true
    done < "$changed_c_files_txt"

    awk -v root="$repo_dir/" '
    match($0, /^([^:]+):([0-9]+):([0-9]+): (warning|error|fatal error): (.*)$/, m) {
      f=m[1]; l=m[2]; c=m[3]; s=m[4]; msg=m[5];
      if (s == "fatal error") {
        s = "error";
      }
      sub("^" root, "", f);
      print f "\t" l "\t" c "\t" s "\t" msg;
    }' "$clang_semantic_log" | sort -u > "$clang_semantic_raw_tsv"

    if [[ -s "$clang_semantic_raw_tsv" ]]; then
      clang_semantic_diag_total="$(wc -l < "$clang_semantic_raw_tsv" | tr -d ' ')"
      while IFS=$'\t' read -r file line col sev msg; do
        [[ -n "$file" && -n "$line" && -n "$msg" ]] || continue
        if ! grep -Fqx "$file" "$changed_c_files_txt"; then
          continue
        fi

        if printf '%s' "$msg" | grep -Eqi 'unused parameter'; then
          add_finding "medium" "maintainability" "${file}:${line}" \
            "clang: ${msg}" \
            "Unused API/function parameters often indicate missing validation or stale contract design." \
            "Remove unused parameters or enforce explicit validation/usage in the call path." \
            "CLANG-UNUSED-PARAM" "https://clang.llvm.org/docs/DiagnosticsReference.html#wunused-parameter"
          clang_semantic_inline_included=$((clang_semantic_inline_included + 1))
        elif printf '%s' "$msg" | grep -Eqi 'null|dereference|function pointer is null'; then
          add_finding "high" "correctness" "${file}:${line}" \
            "clang analyzer: ${msg}" \
            "Potential null/function-pointer dereference can cause immediate runtime crash." \
            "Add nullability checks and fail-safe error handling before dereference/call." \
            "CLANG-NULL-DEREF" "https://clang.llvm.org/docs/analyzer/checkers.html#core-nulldereference"
          clang_semantic_inline_included=$((clang_semantic_inline_included + 1))
        elif printf '%s' "$msg" | grep -Eqi 'dead store|never read'; then
          add_finding "medium" "correctness" "${file}:${line}" \
            "clang analyzer: ${msg}" \
            "Dead stores often indicate dropped error/status propagation and latent logic defects." \
            "Propagate or consume status values explicitly; remove dead assignments." \
            "CLANG-DEAD-STORE" "https://clang.llvm.org/docs/analyzer/checkers.html#deadcode-deadstores"
          clang_semantic_inline_included=$((clang_semantic_inline_included + 1))
        fi
      done < "$clang_semantic_raw_tsv"
    fi
    clang_semantic_suppressed=$((clang_semantic_diag_total - clang_semantic_inline_included))
    if [[ "$clang_semantic_suppressed" -lt 0 ]]; then
      clang_semantic_suppressed=0
    fi
  fi
fi

# Model-assisted bug signal (optional): inject bug-family/location findings into the same review flow.
run_bug_model_signal
inject_high_risk_model_fallback_comment
inject_risk_only_model_fallback_comment

# Emit flawfinder findings after model signal so we can suppress line-duplicate comments.
if [[ -s "$flawfinder_raw_tsv" ]]; then
  while IFS=$'\t' read -r sev cat loc evidence risk action rid rsrc rconf; do
    [[ -n "$sev" && -n "$loc" ]] || continue
    if [[ "$rid" == FF-* ]] && grep -Fqx "$loc" "$model_comment_locations_txt"; then
      flawfinder_findings_deduped=$((flawfinder_findings_deduped + 1))
      continue
    fi
    add_finding "$sev" "$cat" "$loc" "$evidence" "$risk" "$action" "$rid" "$rsrc"
    flawfinder_findings_emitted=$((flawfinder_findings_emitted + 1))
  done < "$flawfinder_raw_tsv"
fi

# Emit external YAML findings after model signal for file:line dedup.
if [[ -s "$external_yaml_raw_tsv" ]]; then
  while IFS=$'\t' read -r sev cat loc evidence risk action rid rsrc rconf; do
    [[ -n "$sev" && -n "$loc" ]] || continue
    if [[ "$rid" == SG-* ]] && grep -Fqx "$loc" "$model_comment_locations_txt"; then
      external_yaml_findings_deduped=$((external_yaml_findings_deduped + 1))
      continue
    fi
    add_finding "$sev" "$cat" "$loc" "$evidence" "$risk" "$action" "$rid" "$rsrc"
    external_yaml_findings_emitted=$((external_yaml_findings_emitted + 1))
  done < "$external_yaml_raw_tsv"
fi

# Build deterministic comment-submit batches for human-approved posting.
proposed_comments_total=0
comment_batches_total=0
if [[ -s "$proposed_comments_tsv" ]]; then
  proposed_comments_total="$(wc -l < "$proposed_comments_tsv" | tr -d ' ')"
  if [[ "$proposed_comments_total" -gt 0 ]]; then
    comment_batches_total=$(( (proposed_comments_total + comment_batch_size - 1) / comment_batch_size ))
    for ((b=1; b<=comment_batches_total; b++)); do
      start=$(( (b - 1) * comment_batch_size + 1 ))
      end=$(( b * comment_batch_size ))
      if [[ "$end" -gt "$proposed_comments_total" ]]; then
        end="$proposed_comments_total"
      fi
      echo "- Batch ${b}/${comment_batches_total}: comments ${start}-${end} of ${proposed_comments_total}" >> "$comment_batches_md"
    done
  fi
fi

comment_filter_reject_total=0
comment_filter_reject_summary="none"
if [[ -s "$comment_filter_rejects_tsv" ]]; then
  comment_filter_reject_total="$(wc -l < "$comment_filter_rejects_tsv" | tr -d ' ')"
  comment_filter_reject_summary="$(awk -F'\t' '
{ r[$5]++ }
END {
  first=1
  for (k in r) {
    if (!first) printf ", "
    printf "%s=%d", k, r[k]
    first=0
  }
}' "$comment_filter_rejects_tsv" | tr -d '\n')"
  [[ -n "$comment_filter_reject_summary" ]] || comment_filter_reject_summary="none"
fi

# Optional clean finding when nothing else found.
if [[ ! -s "$findings_md" && "$include_clean" -eq 1 ]]; then
  add_finding "low" "process" "review-summary" "No high/medium findings were derived from fetched signals." "Automated signal review does not replace deep manual reasoning." "Run targeted manual pass on critical execution paths before final approval."
fi

# Research-derived grouped task checklist (Linux/QEMU/Python/Kubernetes/Google/Go/Node/Rust/OWASP).
emit_group "Linux Kernel Submission Checklist"
emit_task "$(task_status_not_bool "$pr_draft")" "Patch series is ready for review (not marked draft)."
emit_task "$(task_status_bool "$( [[ "$files_count" -le 25 && "$total_additions" -le 800 ]] && echo true || echo false )")" "Patch scope is reviewable (prefer smaller logical changes)."
emit_task "$(task_status_bool "$( [[ "$checkpatch_errors" -eq 0 && "$checkpatch_warnings" -eq 0 ]] && echo true || echo false )")" "Style/tooling gate clean (checkpatch errors/warnings resolved)."
emit_task "$(task_status_bool "$tests_changed")" "Changed behavior has explicit test updates."
emit_task "$(task_status_bool "$docs_changed")" "Documentation updates accompany code changes."
emit_task "$(task_status_bool "$api_surface_changed")" "Public API/ABI changes are explicitly called out for compatibility review."
emit_task "needs-input" "Kconfig impacts are reviewed for defaults, dependencies, and menu/help text correctness."
emit_task "needs-input" "Kernel-doc / rst documentation updates are complete for new user-visible behavior."
emit_task "needs-input" "Patch description explains problem, impact, and why this implementation is chosen."
emit_task "needs-input" "Patch separation is logical; mechanical/code-motion changes are isolated from semantic changes."
emit_task "needs-input" "Recipients include relevant maintainers/subsystems (get_maintainer-like coverage)."
emit_task "needs-input" "Security-sensitive fixes are routed with proper disclosure process where applicable."
emit_task "needs-input" "Review replies are interleaved/trimmed and each review concern is addressed explicitly."
emit_task "needs-input" "Patch resend cadence follows patience guidance (avoid premature pings/reposts)."
emit_task "needs-input" "Build matrix evidence captured (=y/=m/=n, all*config, cross-arch, docs build where relevant)."
emit_task "needs-input" "Subsystem maintainers and required reviewers were CC'd/engaged."

emit_group "QEMU Patch Workflow Expectations"
emit_task "$(task_status_bool "$( [[ "$commits_count" -le 20 ]] && echo true || echo false )")" "Patch history is reviewable; series size is manageable."
emit_task "$(task_status_bool "$issue_ref_present")" "Problem statement and issue linkage are explicit in PR description."
emit_task "$(task_status_bool "$tests_changed")" "Tests/regressions included or clearly justified."
emit_task "$(task_status_bool "$docs_changed")" "Documentation impact addressed."
emit_task "needs-input" "Patch base is current master (minimal rebase friction for reviewers)."
emit_task "needs-input" "Code-motion patches are isolated to aid mechanical review."
emit_task "needs-input" "Irrelevant churn (whitespace/renames/noise) is avoided in semantic patches."
emit_task "needs-input" "Commit messages include meaningful rationale and behavioral impact, not only mechanics."
emit_task "needs-input" "Series metadata includes proper versioning/changelog notes across revisions."
emit_task "needs-input" "Reviewed-by/Tested-by tags are used correctly and preserved appropriately."
emit_task "needs-input" "Submission channel requirements are respected (inline patches, no attachment-only flow)."
emit_task "needs-input" "Tooling workflow (b4/git-publish equivalents) captures CC lists and submission hygiene."
emit_task "needs-input" "Patch submission metadata and mailing-list/maintainer process expectations satisfied."
emit_task "needs-input" "Reviewer feedback loop tracked with timely follow-up revisions."
emit_task "needs-input" "Performance-sensitive changes include rationale/measurement where needed."
emit_task "needs-input" "Commit messages explain why, not only what."

emit_group "Python Core Accepting PRs Mindset"
emit_task "needs-input" "Contributor legal checks (CLA or project equivalent) are satisfied."
emit_task "$(task_status_bool "$news_changed")" "Release note/news entry present for user-visible change."
emit_task "$(task_status_bool "$tests_changed")" "Automated tests updated for behavior/API changes."
emit_task "$(task_status_bool "$docs_changed")" "User/developer docs updated with behavior changes."
emit_task "$(task_status_bool "$issue_ref_present")" "PR references issue/problem context."
emit_task "needs-input" "PR targets correct branch first; backports handled as follow-up per branch policy."
emit_task "needs-input" "Pull request lifecycle checks are complete (triage labels, state, and reviewers assigned)."
emit_task "needs-input" "Local patchcheck-equivalent automation is run and clean before merge."
emit_task "needs-input" "Backward-compatibility risks are justified with strong rationale if behavior changes."
emit_task "needs-input" "Commit hygiene follows focused-change guidance (avoid bundling unrelated fixes)."
emit_task "needs-input" "CI failures are triaged and dispositioned (infra flake vs real regression)."
emit_task "needs-input" "Reviewer comments include concrete test results/environment details when validating fixes."
emit_task "needs-input" "Reverts/cherry-picks/backports preserve metadata and policy compliance."
emit_task "needs-input" "All required CI checks passed before final approval."
emit_task "needs-input" "Backport policy/labels considered when applicable."
emit_task "needs-input" "Merge readiness confirms no unresolved blocking review threads."

emit_group "Kubernetes PR Process Practices"
emit_task "$(task_status_bool "$( [[ "$files_count" -le 25 ]] && echo true || echo false )")" "PR remains focused and scoped."
emit_task "$(task_status_bool "$tests_changed")" "Pre-submit verification/test changes present."
emit_task "$(task_status_bool "$release_notes_changed")" "Release note / user impact messaging present."
emit_task "$(task_status_bool "$docs_changed")" "Documentation/process guidance updated where behavior changed."
emit_task "$(task_status_bool "$issue_ref_present")" "Issue/bug link is explicit for traceability."
emit_task "needs-input" "Local verify/test/integration targets are executed before requesting review."
emit_task "needs-input" "CLA gating is satisfied and bot checks are green."
emit_task "needs-input" "e2e expectations are met or waived with explicit rationale."
emit_task "needs-input" "PR hold/WIP semantics are used correctly during unfinished phases."
emit_task "needs-input" "Conventions docs (coding/API/kubectl) are followed for touched areas."
emit_task "needs-input" "KEP requirement is satisfied for feature-level changes."
emit_task "needs-input" "Commit message conventions (subject/body/imperative/wrapping) are followed."
emit_task "needs-input" "Release-note quality passes reviewer criteria (purpose, impact, grammar)."
emit_task "needs-input" "Project bot labels/ownership rules satisfied."
emit_task "needs-input" "Approval counts/OWNERS gates satisfied before merge."
emit_task "needs-input" "Cherry-pick/backport and branch policy addressed if required."

emit_group "Google Code Review Standard"
emit_task "attention" "Change should improve overall code health; reject if net health degrades."
emit_task "$(task_status_bool "$tests_changed")" "Correctness confidence improved through tests or validation evidence."
emit_task "$(task_status_bool "$docs_changed")" "Maintainability improved through docs/comments/API clarity."
emit_task "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 ]] && echo true || echo false )")" "No unresolved blocking quality defects remain."
emit_task "needs-input" "Reviewer explicitly records which parts/aspects were reviewed when review scope is partial."
emit_task "needs-input" "High-level design concerns are addressed before line-level nits."
emit_task "needs-input" "Complexity and readability concerns are resolved before approval."
emit_task "needs-input" "Security/privacy-critical paths have qualified reviewer attention."
emit_task "needs-input" "Reviewer response latency is reasonable (fast responses, not rushed quality)."
emit_task "needs-input" "Reviewer comments include rationale/explanations, not directive-only requests."
emit_task "needs-input" "Comment severities are labeled (blocker / nit / optional) to prioritize author work."
emit_task "needs-input" "Conflicts are escalated via consensus process instead of stalled comment threads."
emit_task "needs-input" "Comments distinguish blockers vs nits explicitly."
emit_task "needs-input" "Review latency balanced against quality and contributor progress."
emit_task "needs-input" "Code ownership concerns resolved before approval."
emit_task "needs-input" "Final review decision reflects residual risk level."

emit_group "Go Code Review Comments (Generalized)"
emit_task "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 || "$checkpatch_warnings" -gt 0 ]] && echo true || echo false )")" "Formatting/style tools are applied consistently."
emit_task "attention" "Error handling paths should be explicit and actionable."
emit_task "$(task_status_bool "$api_surface_changed")" "API naming and semantics are reviewed for clarity/consistency."
emit_task "$(task_status_bool "$docs_changed")" "Doc comments / package-level docs updated when surface changed."
emit_task "$(task_status_not_bool "$( [[ -n "$todo_lines" ]] && echo true || echo false )")" "No unresolved TODO/FIXME debt introduced without tracking."
emit_task "needs-input" "Doc comments are complete sentences and start with the identifier where applicable."
emit_task "needs-input" "Context propagation/cancellation semantics are preserved in request-scoped operations."
emit_task "needs-input" "Crypto/randomness uses secure primitives for security-sensitive behavior."
emit_task "needs-input" "No panic-style fatal paths are introduced in normal error-handling flow."
emit_task "needs-input" "Error strings are concise, lowercased, and avoid punctuation-only churn."
emit_task "needs-input" "Concurrency lifetimes and goroutine/task cleanup semantics are explicit and safe."
emit_task "needs-input" "Public interfaces avoid surprising signatures and ambiguous initialisms."
emit_task "needs-input" "Tests include stable assertions and readable failure diffs."
emit_task "needs-input" "Tests produce actionable failures (not only pass/fail)."
emit_task "needs-input" "Naming avoids ambiguity and implicit behavior."
emit_task "needs-input" "Error messages/logging avoid leaking sensitive internals."

emit_group "Node.js PR Responsibilities and Workflow"
emit_task "$(task_status_bool "$tests_changed")" "Step-6 style test expectation met (tests updated/run for changed behavior)."
emit_task "$(task_status_bool "$docs_changed")" "Contributor docs/user docs impact handled."
emit_task "$(task_status_bool "$( [[ "$commits_count" -le 20 ]] && echo true || echo false )")" "Patch series kept manageable and rebasable."
emit_task "$(task_status_bool "$issue_ref_present")" "PR discussion context is explicit (issue/problem linkage)."
emit_task "needs-input" "Commit message follows subsystem prefix and conventional body structure."
emit_task "needs-input" "Breaking changes are explicitly identified and documented."
emit_task "needs-input" "Required signoff/metadata fields follow project contribution policy."
emit_task "needs-input" "Rebase and test reruns are completed after review-driven updates."
emit_task "needs-input" "Reviewers focus first on high-impact correctness/design questions."
emit_task "needs-input" "Minimum wait-time expectations for comments are respected."
emit_task "needs-input" "CI matrix is green across required platforms before landing."
emit_task "needs-input" "Subsystem approvals are collected according to collaborator guidance."
emit_task "needs-input" "Required approvals collected per project policy."
emit_task "needs-input" "CI pipelines green and stable before landing."
emit_task "needs-input" "Performance/security implications discussed where relevant."
emit_task "needs-input" "Landing process and merge queue requirements satisfied."

emit_group "Rust API Guidelines Mindset (Language-Agnostic)"
emit_task "$(task_status_bool "$api_surface_changed")" "Public API changes reviewed for consistency and future compatibility."
emit_task "$(task_status_bool "$docs_changed")" "API-level documentation updated for new/changed interfaces."
emit_task "attention" "Naming conventions should match surrounding APIs/subsystems."
emit_task "needs-input" "Naming/casing/conversion patterns remain consistent and unsurprising."
emit_task "needs-input" "Common interoperability traits/contracts are implemented where expected."
emit_task "needs-input" "Error types are meaningful, structured, and ergonomic for callers."
emit_task "needs-input" "Constructors/builders and method placement match API predictability expectations."
emit_task "needs-input" "Argument types encode intent; avoid bool/flag ambiguity where richer types help."
emit_task "needs-input" "Public surface preserves future-proofing (private fields/sealed patterns where appropriate)."
emit_task "needs-input" "Debuggability baseline exists (useful debug representations and diagnostics)."
emit_task "needs-input" "Release notes and metadata are sufficient for downstream integration impact."
emit_task "needs-input" "Error surfaces and failure modes are explicit and documented."
emit_task "needs-input" "Type/data ownership/lifetime assumptions are clear at API boundaries."
emit_task "needs-input" "Interoperability/backward compatibility strategy documented."
emit_task "needs-input" "Examples/tests cover intended API usage and edge behavior."
emit_task "needs-input" "Semver/release impact considered for externally consumed APIs."

emit_group "OWASP Secure Code Review"
emit_task "$(task_status_bool "$security_area_changed")" "Security-sensitive paths identified for deeper review."
emit_task "attention" "Input validation at trust boundaries is explicit and complete."
emit_task "attention" "Encoding/parsing/endianness conversions are validated near boundaries."
emit_task "attention" "Authorization/authentication assumptions are explicit where relevant."
emit_task "attention" "Secrets/credentials leakage checks run on new code."
emit_task "needs-input" "Allowlist-first validation strategy is used for structured inputs and formats."
emit_task "needs-input" "File upload paths validate type/size/storage/serving constraints safely."
emit_task "needs-input" "Authentication controls include brute-force protections and safe recovery paths."
emit_task "needs-input" "Password handling uses strong hashing, secure comparison, and transport protections."
emit_task "needs-input" "Authorization follows deny-by-default and validates access on every request."
emit_task "needs-input" "Least-privilege model is preserved for service and data access operations."
emit_task "needs-input" "Cryptographic design avoids custom algorithms and enforces key lifecycle controls."
emit_task "needs-input" "Logging excludes secrets/PII while preserving auditability and tamper resistance."
emit_task "needs-input" "Error handling avoids disclosure while preserving operational diagnostics internally."
emit_task "needs-input" "Threat-based review checks business-logic abuse, race conditions, and trust boundary bypasses."
emit_task "needs-input" "Threat model or abuse-case impact assessed for this change."
emit_task "needs-input" "Security logging/audit implications reviewed."
emit_task "needs-input" "Manual security review outcome recorded for merge decision."

emit_matrix_group "Linux Coding-Style Rule Matrix"
emit_matrix_rule "LNX-CS-1" "Indentation uses tabs where required." "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 || "$checkpatch_warnings" -gt 0 ]] && echo true || echo false )")" "Derived from checkpatch/tab-space diagnostics." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#indentation"
emit_matrix_rule "LNX-CS-2" "Long lines and strings are wrapped appropriately." "$(task_status_not_bool "$( grep -Eqi 'line over' "$checkpatch_log" && echo true || echo false )")" "Line-length issues inferred from style tool output." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#breaking-long-lines-and-strings"
emit_matrix_rule "LNX-CS-3" "Braces and spaces follow canonical style." "$(task_status_not_bool "$( grep -Eqi 'brace|spacing' "$checkpatch_log" && echo true || echo false )")" "Brace/spacing findings inferred from style diagnostics." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#placing-braces-and-spaces"
emit_matrix_rule "LNX-CS-4" "Naming follows kernel conventions and avoids ambiguous abbreviations." "needs-input" "Requires semantic naming review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#naming"
emit_matrix_rule "LNX-CS-5" "Typedef usage is minimal and justified." "needs-input" "Requires explicit type-API review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#typedefs"
emit_matrix_rule "LNX-CS-6" "Functions stay small and focused with readable structure." "needs-input" "Requires manual function complexity review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#functions"
emit_matrix_rule "LNX-CS-7" "Function exits are centralized where this improves maintainability." "needs-input" "Requires control-flow review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#centralized-exiting-of-functions"
emit_matrix_rule "LNX-CS-8" "Comments are informative and avoid noise." "needs-input" "Requires human semantic pass on comment quality." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#commenting"
emit_matrix_rule "LNX-CS-9" "Messy code sections are refactored instead of patching around debt." "needs-input" "Requires architectural/code-health review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#you-ve-made-a-mess-of-it"
emit_matrix_rule "LNX-CS-10" "Kconfig changes preserve dependency/help quality." "needs-input" "Only applicable when Kconfig touched; requires human review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#kconfig-configuration-files"
emit_matrix_rule "LNX-CS-11" "Data structures are designed for clarity and evolution." "needs-input" "Requires data-model review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#data-structures"
emit_matrix_rule "LNX-CS-12" "Macros/enums avoid surprises and follow style conventions." "needs-input" "Requires preprocessor and enum review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#macros-enums-and-rtl"
emit_matrix_rule "LNX-CS-13" "Kernel message formatting and log levels are appropriate." "needs-input" "Requires logging semantic review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#printing-kernel-messages"
emit_matrix_rule "LNX-CS-14" "Memory allocation choices and zeroing/error handling are appropriate." "attention" "Allocation patterns need semantic validation." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#allocating-memory"
emit_matrix_rule "LNX-CS-15" "Inline usage is limited to cases with clear value." "needs-input" "Requires performance and readability review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#the-inline-disease"
emit_matrix_rule "LNX-CS-16" "Function return values and names reflect error semantics clearly." "attention" "Unchecked-return heuristic may indicate gaps." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#function-return-values-and-names"
emit_matrix_rule "LNX-CS-17" "Existing kernel/helper macros are reused instead of re-invented logic." "needs-input" "Requires idiom and helper-API review." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#don-t-re-invent-the-kernel-macros"
emit_matrix_rule "LNX-CS-18" "Editor modelines and non-code cruft are absent." "pass" "No obvious modeline/cruft signals in changed files." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#editor-modelines-and-other-cruft"
emit_matrix_rule "LNX-CS-19" "Inline assembly follows documented constraints and readability expectations." "needs-input" "Applicable only when asm touched." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#inline-assembly"
emit_matrix_rule "LNX-CS-20" "Conditional compilation stays readable and minimal." "needs-input" "Requires manual review of preprocessor structure." "https://www.kernel.org/doc/html/v4.17/process/coding-style.html#conditional-compilation"
emit_matrix_rule "LNX-SUBMIT-SPLIT" "Changes are split into logical, reviewable units." "$(task_status_bool "$( [[ "$files_count" -le 25 && "$total_additions" -le 800 ]] && echo true || echo false )")" "Patch size used as proxy for reviewability." "https://www.kernel.org/doc/html/latest/process/submitting-patches.html#separate-your-changes"
emit_matrix_rule "LNX-SUBMIT-STYLECHECK" "Style-check before submission and address diagnostics." "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 || "$checkpatch_warnings" -gt 0 ]] && echo true || echo false )")" "Checkpatch findings are present." "https://www.kernel.org/doc/html/latest/process/submitting-patches.html#style-check-your-changes"
emit_matrix_rule "LNX-SUBMIT-RESPOND" "Review feedback is addressed explicitly across revisions." "needs-input" "Requires thread/revision evidence." "https://www.kernel.org/doc/html/latest/process/submitting-patches.html#respond-to-review-comments"
emit_matrix_rule "LNX-SUBMIT-RECIPIENTS" "Relevant maintainers/reviewers are selected." "needs-input" "Requires CC/recipient evidence." "https://www.kernel.org/doc/html/latest/process/submitting-patches.html#select-the-recipients-for-your-patch"

emit_matrix_group "QEMU Rule Matrix"
emit_matrix_rule "QEMU-SUBMIT-STYLE" "Use QEMU coding style for modified code." "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 || "$checkpatch_warnings" -gt 0 ]] && echo true || echo false )")" "Tooling indicates unresolved style debt." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#use-the-qemu-coding-style"
emit_matrix_rule "QEMU-SUBMIT-SPLIT" "Split long patches into reviewable units." "$(task_status_bool "$( [[ "$files_count" -le 25 ]] && echo true || echo false )")" "Uses file-count proxy for patch chunking." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#split-up-long-patches"
emit_matrix_rule "QEMU-SUBMIT-COMMIT" "Commit message is meaningful and explains rationale." "$(task_status_bool "$issue_ref_present")" "Uses issue/rationale linkage as partial evidence." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#write-a-meaningful-commit-message"
emit_matrix_rule "QEMU-SUBMIT-TEST" "Patches include adequate testing evidence." "$(task_status_bool "$tests_changed")" "Test-file changes used as automated proxy." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#test-your-patches"
emit_matrix_rule "QEMU-SUBMIT-BASE" "Patches are based on current master to reduce rebase churn." "needs-input" "Requires branch ancestry verification." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#base-patches-against-current-git-master"
emit_matrix_rule "QEMU-SUBMIT-MOTION" "Code motion is isolated from functional changes." "needs-input" "Requires diff-structure review." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#make-code-motion-patches-easy-to-review"
emit_matrix_rule "QEMU-SUBMIT-NO-NOISE" "Irrelevant churn is excluded from semantic patches." "needs-input" "Requires patch hygiene review." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#don-t-include-irrelevant-changes"
emit_matrix_rule "QEMU-SUBMIT-REVIEW-RESP" "Author remains engaged and addresses review feedback." "needs-input" "Requires review-thread evidence." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#participating-in-code-review"
emit_matrix_rule "QEMU-SUBMIT-REVIEW-TAGS" "Reviewed-by/Tested-by tags are used appropriately." "needs-input" "Requires commit trailer review." "https://www.qemu.org/docs/master/devel/submitting-a-patch.html#proper-use-of-reviewed-by-tags-can-aid-review"
emit_matrix_rule "QEMU-STYLE-WHITESPACE" "Whitespace and line-width style constraints are followed." "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 || "$checkpatch_warnings" -gt 0 ]] && echo true || echo false )")" "Style warnings indicate potential whitespace/line-width drift." "https://www.qemu.org/docs/master/devel/style.html#formatting-and-style"
emit_matrix_rule "QEMU-STYLE-ERROR-HANDLING" "Error handling/reporting follows project idioms." "needs-input" "Requires semantic path review." "https://www.qemu.org/docs/master/devel/style.html#error-handling-and-reporting"
emit_matrix_rule "QEMU-STYLE-MEMORY" "Memory management and string handling use safe project patterns." "attention" "Low-level memory/string usage requires manual verification." "https://www.qemu.org/docs/master/devel/style.html#low-level-memory-management"

emit_matrix_group "Python Core Rule Matrix"
emit_matrix_rule "PY-COMMIT-CHECKS" "PR passes required checks/tests before merge." "needs-input" "Requires CI status inspection." "https://devguide.python.org/core-team/committing/index.html"
emit_matrix_rule "PY-COMMIT-DOCS" "Documentation updated when behavior changes." "$(task_status_bool "$docs_changed")" "Docs-file changes used as automated proxy." "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
emit_matrix_rule "PY-COMMIT-NEWS" "What's New / NEWS entry included when required." "$(task_status_bool "$news_changed")" "NEWS-like file changes used as proxy." "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
emit_matrix_rule "PY-LIFECYCLE-TEST" "Run tests and patchcheck during PR lifecycle." "$(task_status_bool "$tests_changed")" "Test updates indicate validation intent." "https://raw.githubusercontent.com/python/devguide/main/getting-started/pull-request-lifecycle.rst"
emit_matrix_rule "PY-COMMIT-BRANCH" "PR is against correct branch; backports handled per policy." "needs-input" "Requires branch/label verification." "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
emit_matrix_rule "PY-COMMIT-ISSUE-CONTEXT" "Issue context/discussion is adequate for acceptance decisions." "$(task_status_bool "$issue_ref_present")" "Issue linkage used as proxy." "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
emit_matrix_rule "PY-COMMIT-COMPAT" "Backward-compatibility concerns are justified and documented." "needs-input" "Requires semantic and release-policy review." "https://raw.githubusercontent.com/python/devguide/main/core-team/committing.rst"
emit_matrix_rule "PY-LIFECYCLE-SMALL" "PR remains focused and small enough for effective review." "$(task_status_bool "$( [[ "$files_count" -le 25 ]] && echo true || echo false )")" "File-count proxy used." "https://raw.githubusercontent.com/python/devguide/main/getting-started/pull-request-lifecycle.rst"
emit_matrix_rule "PY-LIFECYCLE-DOCS" "Documentation additions/changes are included when needed." "$(task_status_bool "$docs_changed")" "Docs-file changes detected." "https://raw.githubusercontent.com/python/devguide/main/getting-started/pull-request-lifecycle.rst"
emit_matrix_rule "PY-TRIAGE-LABELS" "Triage labels/assignees/reviewers are set appropriately." "needs-input" "Requires issue/PR metadata review." "https://raw.githubusercontent.com/python/devguide/main/triage/triaging.rst"
emit_matrix_rule "PY-TRIAGE-TESTS" "Bugfix PRs include tests and avoid failing CI." "$(task_status_bool "$tests_changed")" "Test-file changes used as proxy." "https://raw.githubusercontent.com/python/devguide/main/triage/triaging.rst"
emit_matrix_rule "PY-TRIAGE-CONFLICTS" "PR is conflict-free and mergeable." "needs-input" "Requires branch mergeability check." "https://raw.githubusercontent.com/python/devguide/main/triage/triaging.rst"

emit_matrix_group "Kubernetes Rule Matrix"
emit_matrix_rule "K8S-PR-VERIFY" "Run local verification/test commands before PR." "$(task_status_bool "$tests_changed")" "Test-file changes used as proxy; full command evidence may still be needed." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#run-local-verifications"
emit_matrix_rule "K8S-PR-CLA" "CLA and automation gates are satisfied." "needs-input" "Requires bot/check status evidence." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#the-pull-request-submit-process"
emit_matrix_rule "K8S-RN-NEEDED" "Release note present for user-visible changes." "$(task_status_bool "$release_notes_changed")" "Release-note file/path signals used as proxy." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/release-notes.md#does-my-pull-request-need-a-release-note"
emit_matrix_rule "K8S-RN-QUALITY" "Release note includes impact/action-required details." "needs-input" "Requires natural-language quality review." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/release-notes.md#contents-of-a-release-note"
emit_matrix_rule "K8S-PR-FOCUSED" "PR is scoped and avoids repository-wide churn." "$(task_status_bool "$( [[ "$files_count" -le 25 && "$total_additions" -le 800 ]] && echo true || echo false )")" "Patch-size proxy used." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#smaller-is-better-small-commits-small-pull-requests"
emit_matrix_rule "K8S-PR-KEP" "KEP is present when required for feature-level changes." "needs-input" "Requires enhancement metadata review." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#is-the-feature-wanted-file-a-kubernetes-enhancement-proposal"
emit_matrix_rule "K8S-PR-CONVENTIONS" "Touched areas follow coding/API conventions." "needs-input" "Requires subsystem-specific review." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#familiarize-yourself-with-project-conventions"
emit_matrix_rule "K8S-PR-COMMITMSG" "Commit messages follow project guidance." "needs-input" "Requires commit-message quality review." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#commit-message-guidelines"
emit_matrix_rule "K8S-PR-APPROVALS" "Required approvals and ownership gates are met." "needs-input" "Requires PR approval metadata." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/pull-requests.md#the-pull-request-submit-process"
emit_matrix_rule "K8S-RN-CONTENT" "Release notes capture changed object and action-required details." "needs-input" "Requires semantic release-note review." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/release-notes.md#contents-of-a-release-note"
emit_matrix_rule "K8S-RN-WRITING" "Release note wording is user-focused and grammatically sound." "needs-input" "Requires natural-language quality review." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/release-notes.md#writing-good-release-notes"
emit_matrix_rule "K8S-RN-REVIEW" "Release note quality is explicitly reviewed as a dedicated step." "needs-input" "Requires review workflow evidence." "https://raw.githubusercontent.com/kubernetes/community/master/contributors/guide/release-notes.md#reviewing-release-notes"

emit_matrix_group "Google Reviewer Rule Matrix"
emit_matrix_rule "GOOG-STD-CODEHEALTH" "Approve when code health improves overall." "attention" "Requires reviewer judgment beyond static signals." "https://google.github.io/eng-practices/review/reviewer/standard.html"
emit_matrix_rule "GOOG-LOOK-DESIGN" "Design/functionality reviewed before minor style." "needs-input" "Requires explicit review-order evidence." "https://google.github.io/eng-practices/review/reviewer/looking-for.html#design"
emit_matrix_rule "GOOG-COMMENT-SEVERITY" "Comments are severity-labeled for prioritization." "needs-input" "Requires generated/reviewer comment label policy." "https://google.github.io/eng-practices/review/reviewer/comments.html#label-comment-severity"
emit_matrix_rule "GOOG-SPEED-RESP" "Review responses are timely without sacrificing quality." "needs-input" "Requires timeline metadata from review system." "https://google.github.io/eng-practices/review/reviewer/speed.html"
emit_matrix_rule "GOOG-LOOK-FUNCTIONALITY" "Functional behavior and user impact are reviewed explicitly." "needs-input" "Requires behavior-validation evidence." "https://google.github.io/eng-practices/review/reviewer/looking-for.html#functionality"
emit_matrix_rule "GOOG-LOOK-COMPLEXITY" "Unnecessary complexity is reduced before approval." "needs-input" "Requires design-depth review." "https://google.github.io/eng-practices/review/reviewer/looking-for.html#complexity"
emit_matrix_rule "GOOG-LOOK-TESTS" "Test strategy adequacy is reviewed proportionally to risk." "$(task_status_bool "$tests_changed")" "Test-file changes used as proxy." "https://google.github.io/eng-practices/review/reviewer/looking-for.html#tests"
emit_matrix_rule "GOOG-LOOK-DOCS" "Documentation and comments are updated for changed behavior." "$(task_status_bool "$docs_changed")" "Docs-file changes detected." "https://google.github.io/eng-practices/review/reviewer/looking-for.html#documentation"
emit_matrix_rule "GOOG-NAV-SPLIT" "Large CLs are split for navigable review." "$(task_status_bool "$( [[ "$files_count" -le 25 ]] && echo true || echo false )")" "File-count proxy used." "https://google.github.io/eng-practices/review/reviewer/navigate.html#step_two"
emit_matrix_rule "GOOG-COMMENTS-WHY" "Review comments explain why, not only what to change." "needs-input" "Requires review-comment quality inspection." "https://google.github.io/eng-practices/review/reviewer/comments.html#why"
emit_matrix_rule "GOOG-COMMENTS-COURTESY" "Comments remain courteous and objective." "needs-input" "Requires tone review." "https://google.github.io/eng-practices/review/reviewer/comments.html#courtesy"
emit_matrix_rule "GOOG-PUSHBACK-CONFLICT" "Pushback/conflicts are resolved via explicit consensus steps." "needs-input" "Requires thread workflow evidence." "https://google.github.io/eng-practices/review/reviewer/pushback.html#conflicts"

emit_matrix_group "Go Review Rule Matrix"
emit_matrix_rule "GO-CR-GOFMT" "Mechanical formatting tools are applied consistently." "$(task_status_not_bool "$( [[ "$checkpatch_errors" -gt 0 || "$checkpatch_warnings" -gt 0 ]] && echo true || echo false )")" "Style diagnostics indicate unresolved formatting issues." "https://go.dev/wiki/CodeReviewComments#gofmt"
emit_matrix_rule "GO-CR-HANDLE-ERRORS" "Errors are handled explicitly and propagated." "attention" "Static heuristic indicates potential unchecked-path risk." "https://go.dev/wiki/CodeReviewComments#handle-errors"
emit_matrix_rule "GO-CR-DOC-COMMENTS" "Doc comments are complete and consistent." "$(task_status_bool "$docs_changed")" "Docs touched, but quality still needs human validation." "https://go.dev/wiki/CodeReviewComments#doc-comments"
emit_matrix_rule "GO-TEST-DIFFS" "Tests provide actionable failure diffs/messages." "needs-input" "Requires test-content inspection." "https://go.dev/wiki/TestComments#equality-comparison-and-diffs"
emit_matrix_rule "GO-CR-INITIALISMS" "Naming follows initialism and readability conventions." "needs-input" "Requires naming-style review." "https://go.dev/wiki/CodeReviewComments#initialisms"
emit_matrix_rule "GO-CR-IMPORTS" "Imports are clean and semantically appropriate." "needs-input" "Requires import-usage review." "https://go.dev/wiki/CodeReviewComments#imports"
emit_matrix_rule "GO-CR-PANIC" "Panic usage is avoided for expected error flows." "needs-input" "Requires control-flow semantic review." "https://go.dev/wiki/CodeReviewComments#dont-panic"
emit_matrix_rule "GO-CR-CONTEXT" "Context usage is correct for cancellation/security boundaries." "needs-input" "Requires API usage review." "https://go.dev/wiki/CodeReviewComments#contexts"
emit_matrix_rule "GO-CR-CRYPTO" "Security-sensitive randomness uses crypto-safe primitives." "needs-input" "Requires crypto API usage review." "https://go.dev/wiki/CodeReviewComments#crypto-rand"
emit_matrix_rule "GO-CR-GOROUTINES" "Concurrent task lifetimes/cleanup are explicit and safe." "needs-input" "Requires concurrency review." "https://go.dev/wiki/CodeReviewComments#goroutine-lifetimes"
emit_matrix_rule "GO-TEST-NAMES" "Subtest/test names are human-readable and diagnostic." "needs-input" "Requires test content review." "https://go.dev/wiki/TestComments#choose-human-readable-subtest-names"
emit_matrix_rule "GO-TEST-SEMANTICS" "Tests validate error semantics and stable behavior." "needs-input" "Requires test-depth review." "https://go.dev/wiki/TestComments#test-error-semantics"

emit_matrix_group "Node.js Rule Matrix"
emit_matrix_rule "NODE-PR-STEP6" "Test step executed for changed behavior." "$(task_status_bool "$tests_changed")" "Test-file changes used as proxy for step-6 compliance." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#step-6-test"
emit_matrix_rule "NODE-PR-COMMITMSG" "Commit message format and rationale are compliant." "$(task_status_bool "$issue_ref_present")" "Issue linkage used as partial proxy for rationale." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#commit-message-guidelines"
emit_matrix_rule "NODE-TEST-WRITE" "Tests follow project testing recommendations." "needs-input" "Requires test-content quality review." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/writing-tests.md"
emit_matrix_rule "NODE-DOC-WRITE" "Documentation updates include build/lint compliance." "$(task_status_bool "$docs_changed")" "Docs-file changes detected; lint/build evidence may still be required." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/writing-docs.md"
emit_matrix_rule "NODE-PR-BRANCH" "Work is done on dedicated topic branch and rebased as needed." "needs-input" "Requires branch workflow evidence." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#step-2-branch"
emit_matrix_rule "NODE-PR-CODE-AREAS" "Changes follow subsystem ownership boundaries." "needs-input" "Requires subsystem mapping review." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#step-3-code"
emit_matrix_rule "NODE-PR-REBASE" "PR is rebased and conflict-free before landing." "needs-input" "Requires branch ancestry and conflict checks." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#step-5-rebase"
emit_matrix_rule "NODE-PR-DISCUSS" "Review feedback is discussed and updates are iterative." "needs-input" "Requires review-thread evidence." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#step-9-discuss-and-update"
emit_matrix_rule "NODE-PR-APPROVAL" "Approval/request-changes workflow is followed correctly." "needs-input" "Requires PR review-state evidence." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#approval-and-request-changes-workflow"
emit_matrix_rule "NODE-PR-CI" "CI testing matrix passes before landing." "needs-input" "Requires CI status evidence." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#continuous-integration-testing"
emit_matrix_rule "NODE-PR-REVIEW-FOCUS" "Review prioritizes high-impact correctness/design checks first." "needs-input" "Requires reviewer workflow evidence." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/pull-requests.md#review-a-bit-at-a-time"
emit_matrix_rule "NODE-TEST-STRUCTURE" "Tests follow project structure and reliability guidance." "needs-input" "Requires detailed test review." "https://raw.githubusercontent.com/nodejs/node/main/doc/contributing/writing-tests.md#how-to-write-a-good-test"

emit_matrix_group "Rust API Rule Matrix"
emit_matrix_rule "RUST-C-CASE" "Naming and casing conventions remain consistent." "attention" "API naming drift requires manual semantic check." "https://rust-lang.github.io/api-guidelines/checklist.html#c-case"
emit_matrix_rule "RUST-C-FAILURE" "Function docs include error/failure behavior." "$(task_status_bool "$docs_changed")" "Docs changes present, but failure-mode completeness needs review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-failure"
emit_matrix_rule "RUST-C-VALIDATE" "Functions validate arguments at boundaries." "attention" "Boundary-validation depth requires semantic review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-validate"
emit_matrix_rule "RUST-C-RELNOTES" "Significant API changes are captured in release notes." "$(task_status_bool "$release_notes_changed")" "Release-note signals detected by changed-file scan." "https://rust-lang.github.io/api-guidelines/checklist.html#c-relnotes"
emit_matrix_rule "RUST-C-CONV" "Conversion method naming and semantics are conventional." "needs-input" "Requires API naming semantic review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-conv"
emit_matrix_rule "RUST-C-GOOD-ERR" "Error types are meaningful and well-behaved." "needs-input" "Requires error API review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-good-err"
emit_matrix_rule "RUST-C-EXAMPLE" "Public items include usage examples in docs." "$(task_status_bool "$docs_changed")" "Docs presence used as proxy; example completeness needs review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-example"
emit_matrix_rule "RUST-C-METHOD" "Method placement/receiver selection is predictable." "needs-input" "Requires API shape review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-method"
emit_matrix_rule "RUST-C-CUSTOM-TYPE" "Argument types encode meaning instead of ambiguous flags." "needs-input" "Requires parameter-model review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-custom-type"
emit_matrix_rule "RUST-C-DEBUG" "Public types provide useful debug surfaces." "needs-input" "Requires diagnostics review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-debug"
emit_matrix_rule "RUST-C-STRUCT-PRIVATE" "Public structs preserve future-proofing via private fields where appropriate." "needs-input" "Requires type visibility review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-struct-private"
emit_matrix_rule "RUST-C-METADATA" "Metadata and release communication are complete for consumers." "needs-input" "Requires package/release metadata review." "https://rust-lang.github.io/api-guidelines/checklist.html#c-metadata"

emit_matrix_group "OWASP Rule Matrix"
emit_matrix_rule "OWASP-IV-ALLOWLIST" "Input validation follows allowlist-first strategy." "attention" "Boundary validation signals require manual verification." "https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html#allowlist-vs-denylist"
emit_matrix_rule "OWASP-AUTH-GENERIC-ERROR" "Authentication errors avoid user-enumeration leaks." "needs-input" "Requires auth-path behavior inspection." "https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#authentication-and-error-messages"
emit_matrix_rule "OWASP-AUTHZ-PERREQ" "Authorization is enforced on every request." "needs-input" "Requires control-flow and policy verification." "https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html#validate-the-permissions-on-every-request"
emit_matrix_rule "OWASP-CRYPTO-KEYS" "Crypto uses strong algorithms with proper key lifecycle." "needs-input" "Requires implementation-level crypto review." "https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html#key-management"
emit_matrix_rule "OWASP-LOG-DATA-EXCLUDE" "Logs exclude secrets/PII while keeping audit value." "needs-input" "Requires log schema/content review." "https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html#data-to-exclude"
emit_matrix_rule "OWASP-ERR-GENERIC" "User-facing errors are generic; internals stay server-side." "attention" "Error-handling policy requires explicit evidence." "https://cheatsheetseries.owasp.org/cheatsheets/Error_Handling_Cheat_Sheet.html"
emit_matrix_rule "OWASP-SCR-PREP" "Review preparation identifies trust boundaries and high-risk components." "needs-input" "Requires architecture/context documentation." "https://cheatsheetseries.owasp.org/cheatsheets/Secure_Code_Review_Cheat_Sheet.html#preparation"
emit_matrix_rule "OWASP-SCR-DATAFLOW" "Data-flow analysis is performed from entry points to sensitive sinks." "needs-input" "Requires explicit data-flow trace evidence." "https://cheatsheetseries.owasp.org/cheatsheets/Secure_Code_Review_Cheat_Sheet.html#data-flow-analysis"
emit_matrix_rule "OWASP-IV-SERVER-SIDE" "Server-side validation is authoritative over client-side checks." "needs-input" "Requires endpoint/input handling review." "https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html#client-side-vs-server-side-validation"
emit_matrix_rule "OWASP-IV-FILE-UPLOAD" "File upload validation and storage controls are enforced." "needs-input" "Applicable when file uploads are introduced." "https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html#file-upload-validation"
emit_matrix_rule "OWASP-AUTH-PWD-STRENGTH" "Password strength controls meet modern guidance." "needs-input" "Requires auth-policy inspection." "https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#implement-proper-password-strength-controls"
emit_matrix_rule "OWASP-AUTH-BRUTEFORCE" "Brute-force and automated attack mitigations are in place." "needs-input" "Requires auth endpoint protection review." "https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#protect-against-automated-attacks"
emit_matrix_rule "OWASP-AUTHZ-DENY-DEFAULT" "Authorization model is deny-by-default." "needs-input" "Requires policy default review." "https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html#deny-by-default"
emit_matrix_rule "OWASP-AUTHZ-LEAST-PRIV" "Least-privilege principles are enforced." "needs-input" "Requires role/permission model review." "https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html#enforce-least-privileges"
emit_matrix_rule "OWASP-CRYPTO-RNG" "Cryptographic randomness uses secure RNG primitives." "needs-input" "Requires RNG API review." "https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html#secure-random-number-generation"
emit_matrix_rule "OWASP-CRYPTO-ALGOS" "Approved algorithms/modes are used; custom crypto is avoided." "needs-input" "Requires crypto primitive review." "https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html#algorithms"
emit_matrix_rule "OWASP-LOG-EVENTS" "Security-relevant events are logged with sufficient attributes." "needs-input" "Requires event taxonomy review." "https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html#which-events-to-log"
emit_matrix_rule "OWASP-ERR-OBJECTIVE" "Error handling prevents leakage while preserving internal diagnostics." "needs-input" "Requires end-to-end error path review." "https://cheatsheetseries.owasp.org/cheatsheets/Error_Handling_Cheat_Sheet.html#objective"

topic_pass_count="$(grep -Ec '^- \[pass\] ' "$topic_tasks_md" || true)"
topic_attention_count="$(grep -Ec '^- \[attention\] ' "$topic_tasks_md" || true)"
topic_needs_input_count="$(grep -Ec '^- \[needs-input\] ' "$topic_tasks_md" || true)"
topic_total_count="$(grep -Ec '^- \[(pass|attention|needs-input)\] ' "$topic_tasks_md" || true)"
rule_pass_count="$(awk -F'\\|' '/^\\| `/{s=$4; gsub(/[` ]/, "", s); if (s=="pass") c++} END{print c+0}' "$rule_matrix_md")"
rule_attention_count="$(awk -F'\\|' '/^\\| `/{s=$4; gsub(/[` ]/, "", s); if (s=="attention") c++} END{print c+0}' "$rule_matrix_md")"
rule_needs_input_count="$(awk -F'\\|' '/^\\| `/{s=$4; gsub(/[` ]/, "", s); if (s=="needs-input") c++} END{print c+0}' "$rule_matrix_md")"
rule_total_count="$(awk '/^\\| `/{c++} END{print c+0}' "$rule_matrix_md")"

worktree_status="$(git -C "$repo_dir" status --short --branch || true)"
diffstat=""
if git -C "$repo_dir" rev-parse --verify "$base_ref" >/dev/null 2>&1 && git -C "$repo_dir" rev-parse --verify "$head_ref" >/dev/null 2>&1; then
  diffstat="$(git -C "$repo_dir" diff --stat "$base_ref...$head_ref" || true)"
fi

{
  high_count="$(grep -Ec '^### F[0-9]+ - HIGH - ' "$findings_md" || true)"
  medium_count="$(grep -Ec '^### F[0-9]+ - MEDIUM - ' "$findings_md" || true)"
  low_count="$(grep -Ec '^### F[0-9]+ - LOW - ' "$findings_md" || true)"
  echo "# PR Review Report"
  echo
  if [[ -n "$pr_url" ]]; then
    echo "PR: ${pr_url}"
  elif [[ -n "$owner" && -n "$repo" && -n "$pr_number" ]]; then
    echo "PR: https://github.com/${owner}/${repo}/pull/${pr_number}"
  fi
  echo "Fetched at (UTC): ${fetched_at}"
  echo
  echo "## 1. Snapshot"
  echo "- Owner/Repo: ${owner}/${repo}"
  echo "- PR Number: ${pr_number}"
  echo "- Title: ${pr_title}"
  echo "- Base Branch: ${base_branch}"
  echo "- Head Branch: ${head_branch}"
  echo "- Local Diff Base/Head: ${base_ref}...${head_ref}"
  echo "- Files Changed: ${files_count}"
  echo "- Line Delta: +${total_additions} / -${total_deletions}"
  echo "- Review Comments: ${review_comments_count}"
  echo "- PR-level Comments: ${issue_comments_count}"
  echo "- Reviews: ${reviews_count}"
  echo "- Commits in PR: ${commits_count}"
  echo "- Cross-Ecosystem Mode: ${cross_ecosystem_mode}"
  echo "- Autonomous Findings: high=${high_count} medium=${medium_count} low=${low_count}"
  echo "- Precision filter drops: ${comment_filter_reject_total} (${comment_filter_reject_summary})"
  echo "- Precision re-anchors: ${comment_reanchored_total}"
  echo
  echo "## 2. Changed Files"
  echo "| File | Status | + | - |"
  echo "| --- | --- | --- | --- |"
  if [[ -s "$files_rows_md" ]]; then
    cat "$files_rows_md"
  else
    echo "| (none) | - | - | - |"
  fi
  echo
  echo "## 3. Rule Matrices"
  echo "_Per-group rule matrices with explicit source links and status (pass/attention/needs-input)._"
  if [[ "$cross_ecosystem_mode" == "repo-aware" && "$style_family_detected" != "generic" ]]; then
    echo "- Repo-aware filtering active for style family: ${style_family_detected} (omitted matrix groups=${omitted_matrix_groups})"
  fi
  echo "- Matrix coverage: total=${rule_total_count}, pass=${rule_pass_count}, attention=${rule_attention_count}, needs-input=${rule_needs_input_count}"
  cat "$rule_matrix_md"
  echo
  echo "## 4. Research-Derived Review Task Checklist"
  echo "_Actionable checks grouped from Linux/QEMU/Python/Kubernetes/Google/Go/Node/Rust/OWASP review guidance._"
  if [[ "$cross_ecosystem_mode" == "repo-aware" && "$style_family_detected" != "generic" ]]; then
    echo "- Repo-aware filtering active for style family: ${style_family_detected} (omitted task groups=${omitted_topic_groups})"
  fi
  echo "- Task coverage: total=${topic_total_count}, pass=${topic_pass_count}, attention=${topic_attention_count}, needs-input=${topic_needs_input_count}"
  cat "$topic_tasks_md"
  echo
  echo "## 5. Prioritized Findings"
  echo "_Primary signal: autonomous analysis of patch content and repo validation._"
  if [[ -s "$findings_md" ]]; then
    cat "$findings_md"
  else
    echo "No high or medium findings were derived from autonomous patch analysis."
  fi
  echo "## 6. Existing Reviewer Context"
  if [[ -s "$external_notes_md" ]]; then
    sed -n '1,40p' "$external_notes_md"
  else
    echo "- No existing review comments were fetched."
  fi
  echo
  echo "## 7. Open Questions"
  if [[ -s "$open_questions_md" ]]; then
    cat "$open_questions_md"
  else
    echo "- None extracted from comment text."
  fi
  echo
  echo "## 8. Validation Commands"
  echo "1. git -C ${repo_dir} fetch --all --prune"
  echo "2. git -C ${repo_dir} diff --stat ${base_ref}...${head_ref}"
  echo "3. git -C ${repo_dir} log --oneline ${base_ref}..${head_ref}"
  echo "4. Optional style gate: git -C ${repo_dir} format-patch --stdout ${base_ref}..${head_ref} | <checkpatch-cmd> -"
  echo "5. Run repo-specific build/test commands for changed areas"
  echo "6. Re-open unresolved review threads and verify each has a concrete disposition"
  echo
  echo "## 9. Checkpatch Results"
  echo "- Style family: ${style_family_detected}"
  echo "- Checker source: ${checkpatch_source}"
  echo "- Decision path: ${checkpatch_decision}"
  echo "- Command: ${checkpatch_used:-not-detected}"
  echo "- Status: ${checkpatch_status}"
  echo "- Mode: ${checkpatch_mode}"
  echo "- Errors: ${checkpatch_errors}"
  echo "- Warnings: ${checkpatch_warnings}"
  if [[ "$checkpatch_inline_total" -gt 0 ]]; then
    echo "- Inline draft comments from checkpatch: ${checkpatch_inline_included}/${checkpatch_inline_total} (cap=${checkpatch_inline_cap})"
  fi
  if [[ -z "$checkpatch_used" ]]; then
    echo "- Hint needed: provide --style-family or --checkpatch-cmd for stricter style validation."
  fi
  if [[ -n "$checkpatch_summary_line" ]]; then
    echo "- Summary: ${checkpatch_summary_line}"
  fi
  echo "- Advanced semantic engine (clang) available: $([[ "$clang_semantic_available" -eq 1 ]] && echo yes || echo no)"
  echo "- Advanced semantic engine (clang) ran: $([[ "$clang_semantic_ran" -eq 1 ]] && echo yes || echo no)"
  if [[ "$clang_semantic_ran" -eq 1 ]]; then
    echo "- clang semantic diagnostics captured: ${clang_semantic_diag_total}"
    echo "- clang semantic diagnostics converted to findings/comments: ${clang_semantic_inline_included}"
    echo "- clang semantic diagnostics suppressed as low-signal/noise: ${clang_semantic_suppressed}"
  fi
  echo "- Kernel-vuln rule pack ran: $([[ "$kernel_vuln_rules_ran" -eq 1 ]] && echo yes || echo no)"
  if [[ "$kernel_vuln_rules_ran" -eq 1 ]]; then
    echo "- Kernel-vuln rule findings generated: ${kernel_vuln_findings_total}"
  fi
  echo "- Flawfinder static analysis ran: $([[ "$flawfinder_ran" -eq 1 ]] && echo yes || echo no)"
  if [[ "$flawfinder_ran" -eq 1 ]]; then
    echo "- Flawfinder findings parsed: ${flawfinder_findings_pre_filter}"
    echo "- Flawfinder findings diff-adjacent (<= +/-3): ${flawfinder_findings_windowed}"
    echo "- Flawfinder findings post-filter artifact rows: ${flawfinder_findings_total}"
    echo "- Flawfinder findings suppressed by model line dedup: ${flawfinder_findings_deduped}"
    echo "- Flawfinder findings emitted: ${flawfinder_findings_emitted}"
    echo "- Flawfinder minlevel: ${FLAWFINDER_MINLEVEL:-4}"
  fi
  echo "- Diff-native heuristics enabled: $([[ "$diff_native_heuristics" == "1" ]] && echo yes || echo no)"
  if [[ "$diff_native_heuristics" == "1" ]]; then
    echo "- Diff-native window: ${diff_native_window}"
    echo "- Diff-native max findings per rule: ${diff_native_max_findings}"
    echo "- Diff-native strict mode: $([[ "$diff_native_strict" == "1" ]] && echo yes || echo no)"
  fi
  echo "- External YAML static rules ran: $([[ "$external_yaml_ran" -eq 1 ]] && echo yes || echo no)"
  if [[ "$external_yaml_ran" -eq 1 ]]; then
    echo "- External YAML engine: ${external_yaml_engine}"
    echo "- External YAML config: ${external_yaml_config_display}"
    echo "- External YAML findings parsed: ${external_yaml_findings_pre_filter}"
    echo "- External YAML findings diff-adjacent (<= +/-${external_yaml_window}): ${external_yaml_findings_windowed}"
    echo "- External YAML findings post-filter artifact rows: ${external_yaml_findings_total}"
    echo "- External YAML findings suppressed by model line dedup: ${external_yaml_findings_deduped}"
    echo "- External YAML findings emitted: ${external_yaml_findings_emitted}"
    if [[ "${external_yaml_engine}" == "semgrep" || "${external_yaml_engine}" == "gitlab_sast" || "${external_yaml_engine}" == "gitlab-sast" || "${external_yaml_engine}" == "gitlab" || "${external_yaml_engine}" == "gitlab_sast_passthrough" || "${external_yaml_engine}" == "datadog" || "${external_yaml_engine}" == "datadog_custom_rules" || "${external_yaml_engine}" == "datadog-custom-rules" ]]; then
      echo "- External YAML Semgrep rule timeout: ${external_yaml_semgrep_rule_timeout_sec}s"
      echo "- External YAML Semgrep scan timeout: ${external_yaml_semgrep_scan_timeout_sec}s"
      echo "- External YAML Semgrep timeout threshold: ${external_yaml_semgrep_timeout_threshold}"
      echo "- External YAML Semgrep max-target-bytes: ${external_yaml_semgrep_max_target_bytes}"
      echo "- External YAML Semgrep jobs: ${external_yaml_semgrep_jobs}"
      if [[ "${external_yaml_engine}" == "gitlab_sast" || "${external_yaml_engine}" == "gitlab-sast" || "${external_yaml_engine}" == "gitlab" || "${external_yaml_engine}" == "gitlab_sast_passthrough" ]]; then
        echo "- External GitLab SAST ruleset: ${external_yaml_gitlab_ruleset:-unset}"
      elif [[ "${external_yaml_engine}" == "datadog" || "${external_yaml_engine}" == "datadog_custom_rules" || "${external_yaml_engine}" == "datadog-custom-rules" ]]; then
        echo "- External Datadog rules: ${external_yaml_datadog_rules:-unset}"
      fi
    elif [[ "${external_yaml_engine}" == "clang_tidy" || "${external_yaml_engine}" == "clang-tidy" ]]; then
      echo "- External YAML clang-tidy checks: ${external_yaml_clang_tidy_checks}"
      echo "- External YAML clang-tidy timeout: ${external_yaml_clang_tidy_timeout_sec}s"
    elif [[ "${external_yaml_engine}" == "bearer" ]]; then
      echo "- External YAML bearer timeout: ${external_yaml_bearer_timeout_sec}s"
    elif [[ "${external_yaml_engine}" == "codeql" ]]; then
      echo "- External YAML CodeQL DB: ${external_yaml_codeql_db:-unset}"
      echo "- External YAML CodeQL query suite: ${external_yaml_codeql_query_suite}"
      echo "- External YAML CodeQL timeout: ${external_yaml_codeql_timeout_sec}s"
      echo "- External YAML CodeQL cache dir: ${external_yaml_codeql_cache_dir}"
      echo "- External YAML CodeQL cache disabled: $([[ "${external_yaml_codeql_cache_disable}" == "1" ]] && echo yes || echo no)"
    fi
  fi
  echo "- Model-assisted bug detector ran: $([[ "$bug_model_ran" -eq 1 ]] && echo yes || echo no)"
  echo "- Model-assisted bug detector status: ${bug_model_status}"
  echo "- Model source: ${bug_model_source}"
  if [[ "$bug_model_status" == "ok" ]]; then
    echo "- Model artifact: ${bug_model_path}"
    echo "- Model thresholds: binary=${bug_binary_threshold}, family=${bug_family_threshold}, hunk=${bug_hunk_threshold}, topk_hunks=${bug_topk_hunks}"
    echo "- Model guarded-risk min hunk: ${bug_guarded_risk_min_hunk}"
    echo "- Model high-risk fallback threshold: ${bug_high_risk_fallback_threshold}"
    echo "- Model risk-only fallback threshold: ${bug_risk_only_fallback_threshold:-disabled}"
    echo "- Model review mode: ${bug_model_review_mode:-unknown}"
    echo "- Model risk score: ${bug_model_risk_score}"
    echo "- Model predicted family: ${bug_model_family:-unknown} (score=${bug_model_family_score})"
    echo "- Model top hunk: ${bug_model_hunk_file:-n/a}:${bug_model_hunk_line:-n/a} (confidence=${bug_model_best_hunk_score})"
    echo "- Model commit-memory hit: ${bug_model_memory_used}"
    echo "- Model fallback draft injected: $([[ "$bug_model_fallback_injected" -eq 1 ]] && echo yes || echo no)"
    echo "- Model risk-only fallback injected: $([[ "$bug_model_risk_fallback_injected" -eq 1 ]] && echo yes || echo no)"
  fi
  echo
  echo '```text'
  echo "checkpatch log (first 20 lines):"
  sed -n '1,20p' "$checkpatch_log"
  if [[ "$clang_semantic_ran" -eq 1 ]]; then
    echo
    echo "clang semantic log (first 20 lines):"
    sed -n '1,20p' "$clang_semantic_log"
  fi
  if [[ "$kernel_vuln_rules_ran" -eq 1 ]]; then
    echo
    echo "kernel-vuln rules log (first 20 lines):"
    sed -n '1,20p' "$kernel_vuln_log"
  fi
  echo '```'
  echo
  echo "## 10. Proposed Review Comments (Human Approval Required)"
  echo "_Draft comments generated from autonomous findings. Do not submit automatically. A human must approve each item before posting._"
  if [[ "$checkpatch_inline_total" -gt 0 ]]; then
    echo "- checkpatch-derived inline drafts: ${checkpatch_inline_included}/${checkpatch_inline_total} (cap=${checkpatch_inline_cap})"
  fi
  echo "- total draft comments: ${proposed_comments_total}"
  echo "- precision filter drops: ${comment_filter_reject_total}"
  echo "- precision re-anchors: ${comment_reanchored_total}"
  echo "- batch size for submission planning: ${comment_batch_size}"
  if [[ -s "$proposed_comments_md" ]]; then
    cat "$proposed_comments_md"
  else
    echo "- No file/line-targeted draft comments were generated from current findings."
  fi
  echo
  echo "## 11. Comment Submission Batches (Human Gate)"
  echo "_Submit only after human approval/edit of every draft comment. Use batches to avoid oversized review payloads._"
  if [[ -s "$comment_batches_md" ]]; then
    cat "$comment_batches_md"
  else
    echo "- No comment batches needed (no draft comments generated)."
  fi
  echo
  echo "## 12. Reviewer Response Workflow"
  echo "1. Post one reply per finding with status: fixed / clarified / rejected-with-rationale."
  echo "2. Link commit hashes for code changes that address each finding."
  echo "3. Keep unresolved items explicit and request author follow-up where needed."
  echo "4. Human gate: approve or edit every proposed review comment before submission."
  echo "5. Submit final review as Approve, Comment, or Request changes based on remaining high/medium findings."
  echo
  echo "## 13. Local Repo Status"
  echo '```text'
  if [[ -n "$diffstat" ]]; then
    echo "Diffstat (${base_ref}...${head_ref}):"
    echo "$diffstat"
  else
    echo "Diffstat unavailable for ${base_ref}...${head_ref}"
  fi
  echo
  echo "Worktree status:"
  if [[ -n "$worktree_status" ]]; then
    echo "$worktree_status"
  else
    echo "(clean)"
  fi
  echo '```'
} > "$report_md"

{
  echo "# Draft Review Comments"
  echo
  echo "PR: ${owner}/${repo} #${pr_number} - ${pr_title}"
  echo
  echo "_Draft-only until human approval._"
  echo
  if [[ -s "$proposed_comments_tsv" ]]; then
    cidx=0
    while IFS=$'\t' read -r sev file line msg; do
      link="$(build_comment_permalink "$file" "$line" || true)"
      cidx=$((cidx + 1))
      echo "## C${cidx}"
      echo "- Severity: ${sev^^}"
      echo "- Location: ${file}:${line}"
      if [[ -n "$link" ]]; then
        echo "- Link: ${link}"
      fi
      echo "- Comment: ${msg}"
      echo
    done < "$proposed_comments_tsv"
  else
    echo "- No draft comments generated."
    echo
  fi
  echo "## Open Questions"
  if [[ -s "$open_questions_md" ]]; then
    cat "$open_questions_md"
  else
    echo "- None."
  fi
} > "$review_comments_md"

review_comments_out="$context_dir/review_comments.md"
artifact_out_dir="$context_dir"
if [[ -n "$report_file" ]]; then
  review_comments_out="$(dirname "$report_file")/review_comments.md"
  artifact_out_dir="$(dirname "$report_file")"
elif [[ -n "$output_file" ]]; then
  review_comments_out="$(dirname "$output_file")/review_comments.md"
  artifact_out_dir="$(dirname "$output_file")"
fi
cp "$review_comments_md" "$review_comments_out"
if [[ "$flawfinder_ran" -eq 1 ]]; then
  cp "$flawfinder_raw_tsv" "$artifact_out_dir/flawfinder_findings.tsv"
fi
if [[ "$external_yaml_ran" -eq 1 ]]; then
  cp "$external_yaml_raw_tsv" "$artifact_out_dir/external_yaml_findings.tsv"
fi

if [[ -n "$report_file" ]]; then
  cp "$report_md" "$report_file"
fi

if [[ -n "$output_file" ]]; then
  cp "$report_md" "$output_file"
else
  cat "$report_md"
fi
