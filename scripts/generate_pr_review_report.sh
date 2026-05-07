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
  --no-fetch-checkpatch Disable remote fetch fallback when local checker is missing
  --allow-scope-mismatch Do not fail when local diff file set differs from GitHub PR file set
  --output <file>       Write report to file (default: stdout)
  --report-file <file>  Overwrite this report file directly
  --include-clean       Include explicit low-severity clean findings when no blockers are detected
  -h, --help            Show help
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
comment_batches_md="$tmp_dir/comment_batches.md"
checkpatch_log="$tmp_dir/checkpatch.log"
checkpatch_inline_raw_tsv="$tmp_dir/checkpatch_inline_raw.tsv"
clang_semantic_log="$tmp_dir/clang_semantic.log"
clang_semantic_raw_tsv="$tmp_dir/clang_semantic_raw.tsv"
changed_c_files_txt="$tmp_dir/changed_c_files.txt"
added_lines_tsv="$tmp_dir/added_lines.tsv"
pr_files_txt="$tmp_dir/pr_files.txt"
local_files_txt="$tmp_dir/local_files.txt"
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
: > "$comment_batches_md"
: > "$checkpatch_log"
: > "$checkpatch_inline_raw_tsv"
: > "$clang_semantic_log"
: > "$clang_semantic_raw_tsv"
: > "$changed_c_files_txt"
: > "$added_lines_tsv"
: > "$pr_files_txt"
: > "$local_files_txt"

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

finding_id=0
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

  key_evidence="$(printf '%s' "$evidence" | sed 's/[[:space:]]\+/ /g')"
  key="${file}:${line}|${category}|${key_evidence}|${rule_id}|${rule_link}"
  if grep -Fqx "$key" "$proposed_comments_seen"; then
    return 1
  fi
  echo "$key" >> "$proposed_comments_seen"

  msg="Potential ${category} issue: ${evidence} Recommended: ${action}"
  if [[ -n "$rule_id" ]]; then
    msg="${msg} Rule: ${rule_id}."
  fi
  if [[ -n "$rule_link" ]]; then
    msg="${msg} Source: ${rule_link}."
  fi
  msg="$(printf '%s' "$msg" | sed 's/[[:space:]]\+/ /g' | sed 's/`//g')"
  {
    echo "- [ ] ${severity^^} | ${file}:${line}"
    echo "  - Draft comment: ${msg}"
  } >> "$proposed_comments_md"
  printf '%s\t%s\t%s\t%s\n' "$severity" "$file" "$line" "$msg" >> "$proposed_comments_tsv"
  return 0
}

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
done < <(awk -F'\t' '($3 ~ /(except[[:space:]]+Exception|catch[[:space:]]*\([[:space:]]*Exception[[:space:]]*[a-zA-Z0-9_]*[[:space:]]*\)|catch[[:space:]]*\(\.\.\.\)|rescue[[:space:]]+StandardError)/) {print $1 "\t" $2 "\t" $3}' "$added_lines_tsv" | sed -n '1,10p')

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

# Existing reviewer comments are context by default; include as findings only when requested.
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
  echo "### ${title}" >> "$topic_tasks_md"
}

emit_task() {
  local status="$1"
  local text="$2"
  echo "- [${status}] ${text}" >> "$topic_tasks_md"
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
  {
    echo "### ${title}"
    echo "| Rule ID | Rule | Status | Evidence/Notes | Source |"
    echo "| --- | --- | --- | --- | --- |"
  } >> "$rule_matrix_md"
}

emit_matrix_rule() {
  local rule_id="$1"
  local rule_text="$2"
  local status="$3"
  local note="$4"
  local source_link="$5"
  printf '| `%s` | %s | `%s` | %s | %s |\n' "$rule_id" "$rule_text" "$status" "$note" "$source_link" >> "$rule_matrix_md"
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
clang_semantic_warnings=0
clang_semantic_inline_total=0
clang_semantic_inline_included=0

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
  /^ERROR:[[:space:]]*/ {
    sev="high"
    msg=$0
    sub(/^ERROR:[[:space:]]*/, "", msg)
    next
  }
  /^WARNING:[[:space:]]*/ {
    sev="medium"
    msg=$0
    sub(/^WARNING:[[:space:]]*/, "", msg)
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
    checkpatch_errors="$(grep -Eci '(^ERROR:|[[:space:]]ERROR:|[[:space:]]error:)' "$checkpatch_log" || true)"
    checkpatch_warnings="$(grep -Eci '(^WARNING:|[[:space:]]WARNING:|[[:space:]]warning:)' "$checkpatch_log" || true)"
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
    match($0, /^([^:]+):([0-9]+):([0-9]+): (warning|error): (.*)$/, m) {
      f=m[1]; l=m[2]; c=m[3]; s=m[4]; msg=m[5];
      sub("^" root, "", f);
      print f "\t" l "\t" c "\t" s "\t" msg;
    }' "$clang_semantic_log" | sort -u > "$clang_semantic_raw_tsv"

    if [[ -s "$clang_semantic_raw_tsv" ]]; then
      clang_semantic_inline_total="$(wc -l < "$clang_semantic_raw_tsv" | tr -d ' ')"
      while IFS=$'\t' read -r file line col sev msg; do
        [[ -n "$file" && -n "$line" && -n "$msg" ]] || continue
        if ! grep -Fqx "$file" "$changed_c_files_txt"; then
          continue
        fi
        clang_semantic_warnings=$((clang_semantic_warnings + 1))

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
  fi
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
  echo "- Autonomous Findings: high=${high_count} medium=${medium_count} low=${low_count}"
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
  echo "- Matrix coverage: total=${rule_total_count}, pass=${rule_pass_count}, attention=${rule_attention_count}, needs-input=${rule_needs_input_count}"
  cat "$rule_matrix_md"
  echo
  echo "## 4. Research-Derived Review Task Checklist"
  echo "_Actionable checks grouped from Linux/QEMU/Python/Kubernetes/Google/Go/Node/Rust/OWASP review guidance._"
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
    echo "- clang semantic diagnostics captured: ${clang_semantic_inline_total}"
    echo "- clang semantic diagnostics converted to findings/comments: ${clang_semantic_inline_included}"
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
  echo '```'
  echo
  echo "## 10. Proposed Review Comments (Human Approval Required)"
  echo "_Draft comments generated from autonomous findings. Do not submit automatically. A human must approve each item before posting._"
  if [[ "$checkpatch_inline_total" -gt 0 ]]; then
    echo "- checkpatch-derived inline drafts: ${checkpatch_inline_included}/${checkpatch_inline_total} (cap=${checkpatch_inline_cap})"
  fi
  echo "- total draft comments: ${proposed_comments_total}"
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

if [[ -n "$report_file" ]]; then
  cp "$report_md" "$report_file"
fi

if [[ -n "$output_file" ]]; then
  cp "$report_md" "$output_file"
else
  cat "$report_md"
fi
