#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build synthetic local PR review contexts from selected introducing commits.

Usage:
  build_local_pr_context_from_commit.sh \
    --repo-dir <git-repo> \
    --selection-json <selection.json> \
    --out-root <dir> \
    [--owner local] \
    [--repo-name <name>]

Output per selected case:
  <out-root>/<NN>_<intro12>/
    pr.json
    files.json
    review_comments.json
    issue_comments.json
    reviews.json
    commits.json
    summary.txt
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing command: $1"
}

repo_dir=""
selection_json=""
out_root=""
owner="local"
repo_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)
      repo_dir="${2:-}"
      shift 2
      ;;
    --selection-json)
      selection_json="${2:-}"
      shift 2
      ;;
    --out-root)
      out_root="${2:-}"
      shift 2
      ;;
    --owner)
      owner="${2:-local}"
      shift 2
      ;;
    --repo-name)
      repo_name="${2:-}"
      shift 2
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

require_cmd git
require_cmd jq
require_cmd python3

[[ -n "$repo_dir" ]] || err "--repo-dir is required"
[[ -d "$repo_dir/.git" ]] || err "Invalid --repo-dir (missing .git): $repo_dir"
[[ -n "$selection_json" ]] || err "--selection-json is required"
[[ -f "$selection_json" ]] || err "Selection file not found: $selection_json"
[[ -n "$out_root" ]] || err "--out-root is required"
mkdir -p "$out_root"

if [[ -z "$repo_name" ]]; then
  repo_name="$(basename "$repo_dir")"
fi

count="$(jq '.selected | length' "$selection_json")"
[[ "$count" =~ ^[0-9]+$ ]] || err "Invalid selection.json schema (.selected must be array)"
[[ "$count" -gt 0 ]] || err "Selection is empty"

idx=0
while [[ "$idx" -lt "$count" ]]; do
  idx=$((idx + 1))
  row="$(jq -c ".selected[$((idx - 1))]" "$selection_json")"

  intro="$(jq -r '.introducing_commit // empty' <<<"$row" | tr '[:upper:]' '[:lower:]')"
  parent="$(jq -r '.parent // empty' <<<"$row" | tr '[:upper:]' '[:lower:]')"
  fixing="$(jq -r '.fixing_commit // empty' <<<"$row" | tr '[:upper:]' '[:lower:]')"
  bug_type="$(jq -r '.bug_type // "unknown"' <<<"$row")"
  subject="$(jq -r '.subject // empty' <<<"$row")"

  [[ -n "$intro" ]] || err "Row $idx missing introducing_commit"

  full_intro="$(git -C "$repo_dir" rev-parse --verify "${intro}^{commit}" 2>/dev/null | head -n1 || true)"
  [[ -n "$full_intro" ]] || err "Unable to resolve introducing commit: $intro"

  if [[ -z "$parent" ]]; then
    parent="$(git -C "$repo_dir" rev-parse --verify "${full_intro}^" 2>/dev/null | head -n1 || true)"
  else
    parent="$(git -C "$repo_dir" rev-parse --verify "${parent}^{commit}" 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$parent" ]] || err "Unable to resolve parent for introducing commit: $intro"

  if [[ -z "$subject" ]]; then
    subject="$(git -C "$repo_dir" show -s --format=%s "$full_intro" 2>/dev/null || true)"
  fi

  intro12="${full_intro:0:12}"
  parent12="${parent:0:12}"
  case_dir="$(printf "%s/%02d_%s" "$out_root" "$idx" "$intro12")"
  mkdir -p "$case_dir"

  pr_title="Local vulnerable patch ${intro12}: ${subject}"
  pr_body="Synthetic local context bug_type=${bug_type} fixing_commit=${fixing}"
  pr_url="local://${owner}/${repo_name}/${intro12}"

  jq -n \
    --argjson number "$idx" \
    --arg title "$pr_title" \
    --arg html_url "$pr_url" \
    --arg body "$pr_body" \
    --arg owner "$owner" \
    --arg repo "$repo_name" \
    --arg base_ref "$parent12" \
    --arg head_ref "$intro12" \
    '{
      number: $number,
      title: $title,
      html_url: $html_url,
      draft: false,
      body: $body,
      base: {ref: $base_ref, repo: {owner: {login: $owner}, name: $repo}},
      head: {ref: $head_ref}
    }' >"$case_dir/pr.json"

  python3 - "$repo_dir" "$parent" "$full_intro" "$case_dir/files.json" <<'PY'
import json
import subprocess
import sys

repo, parent, intro, out_path = sys.argv[1:5]

def run(cmd):
    out = subprocess.run(cmd, text=True, encoding="utf-8", errors="replace", capture_output=True, check=False)
    return out.stdout

numstat_raw = run(["git", "-C", repo, "diff", "--numstat", f"{parent}..{intro}"])
status_raw = run(["git", "-C", repo, "diff", "--name-status", f"{parent}..{intro}"])

adds = {}
dels = {}
for line in numstat_raw.splitlines():
    parts = line.split("\t")
    if len(parts) < 3:
        continue
    a_raw, d_raw, path = parts[0].strip(), parts[1].strip(), parts[2].strip()
    a = int(a_raw) if a_raw.isdigit() else 0
    d = int(d_raw) if d_raw.isdigit() else 0
    adds[path] = a
    dels[path] = d

rows = []
for line in status_raw.splitlines():
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    code = parts[0].strip().lower()
    path = parts[-1].strip()
    a = adds.get(path, 0)
    d = dels.get(path, 0)
    rows.append(
        {
            "filename": path,
            "status": code[:1] if code else "m",
            "additions": a,
            "deletions": d,
            "changes": a + d,
            "blob_url": "",
        }
    )

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(rows, fh, indent=2)
PY

  commit_msg="$(git -C "$repo_dir" show -s --format=%B "$full_intro" 2>/dev/null || true)"
  jq -n \
    --arg sha "$full_intro" \
    --arg message "$commit_msg" \
    '[{sha: $sha, commit: {message: $message}}]' >"$case_dir/commits.json"

  printf '[]\n' >"$case_dir/review_comments.json"
  printf '[]\n' >"$case_dir/issue_comments.json"
  printf '[]\n' >"$case_dir/reviews.json"

  files_count="$(jq 'length' "$case_dir/files.json")"
  cat >"$case_dir/summary.txt" <<SUMMARY
owner=${owner}
repo=${repo_name}
pr=${idx}
fetched_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
files=${files_count}
review_comments=0
issue_comments=0
reviews=0
commits=1
out_dir=${case_dir}
SUMMARY

  echo "built context: $case_dir (base=${parent12} head=${intro12} bug_type=${bug_type})"
done

echo "done: built ${count} local contexts in ${out_root}"
