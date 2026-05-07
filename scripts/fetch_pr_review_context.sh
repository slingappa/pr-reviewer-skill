#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Fetch GitHub PR review context and emit normalized artifacts.

Usage:
  fetch_pr_review_context.sh --pr-url <url> [--out-dir <dir>] [--token <token>]
  fetch_pr_review_context.sh --owner <owner> --repo <repo> --pr <number> [--out-dir <dir>] [--token <token>]

Options:
  --pr-url <url>      Full PR URL (e.g. https://github.com/org/repo/pull/123)
  --owner <owner>     Repo owner/org
  --repo <repo>       Repo name
  --pr <number>       PR number
  --out-dir <dir>     Output directory (default: /tmp/pr-review-<owner>-<repo>-<pr>)
  --token <token>     GitHub token (fallback to GITHUB_TOKEN env var)
  -h, --help          Show help

Outputs:
  pr.json
  files.json
  review_comments.json
  issue_comments.json
  reviews.json
  commits.json
  files.tsv
  review_comments.tsv
  reviews.tsv
  summary.txt
USAGE
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

owner=""
repo=""
pr=""
pr_url=""
out_dir=""
token="${GITHUB_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url)
      pr_url="${2:-}"
      shift 2
      ;;
    --owner)
      owner="${2:-}"
      shift 2
      ;;
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --pr)
      pr="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    --token)
      token="${2:-}"
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

require_cmd curl
require_cmd jq

if [[ -n "$pr_url" ]]; then
  if [[ "$pr_url" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    pr="${BASH_REMATCH[3]}"
  else
    err "Unable to parse --pr-url. Expected https://github.com/<owner>/<repo>/pull/<number>"
  fi
fi

[[ -n "$owner" ]] || err "Missing owner. Use --owner/--repo/--pr or --pr-url"
[[ -n "$repo" ]] || err "Missing repo. Use --owner/--repo/--pr or --pr-url"
[[ -n "$pr" ]] || err "Missing pr number. Use --owner/--repo/--pr or --pr-url"

if [[ -z "$out_dir" ]]; then
  out_dir="/tmp/pr-review-${owner}-${repo}-${pr}"
fi
mkdir -p "$out_dir"

api_base="https://api.github.com/repos/${owner}/${repo}"

headers=( -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" )
if [[ -n "$token" ]]; then
  headers+=( -H "Authorization: Bearer ${token}" )
fi

fetch_json() {
  local url="$1"
  local out="$2"
  local status

  status="$(curl -sS -L -w '%{http_code}' "${headers[@]}" "$url" -o "$out")"
  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "Request failed: $url (HTTP $status)" >&2
    if [[ -s "$out" ]]; then
      jq -r '.message // empty' "$out" 2>/dev/null >&2 || true
    fi
    exit 1
  fi
}

fetch_json "${api_base}/pulls/${pr}" "$out_dir/pr.json"
fetch_json "${api_base}/pulls/${pr}/files?per_page=100" "$out_dir/files.json"
fetch_json "${api_base}/pulls/${pr}/comments?per_page=100" "$out_dir/review_comments.json"
fetch_json "${api_base}/issues/${pr}/comments?per_page=100" "$out_dir/issue_comments.json"
fetch_json "${api_base}/pulls/${pr}/reviews?per_page=100" "$out_dir/reviews.json"
fetch_json "${api_base}/pulls/${pr}/commits?per_page=100" "$out_dir/commits.json"

jq -r '.[] | [
  .filename,
  (.status // ""),
  ((.additions // 0)|tostring),
  ((.deletions // 0)|tostring),
  ((.changes // 0)|tostring),
  (.blob_url // "")
] | @tsv' "$out_dir/files.json" > "$out_dir/files.tsv"

jq -r '.[] | [
  .id,
  .user.login,
  (.path // ""),
  ((.line // .original_line // "")|tostring),
  ((.in_reply_to_id // "")|tostring),
  (.body|gsub("\\n";" ")),
  .html_url
] | @tsv' "$out_dir/review_comments.json" > "$out_dir/review_comments.tsv"

jq -r '.[] | [
  .id,
  .user.login,
  (.state // ""),
  (.submitted_at // ""),
  (.body|gsub("\\n";" "))
] | @tsv' "$out_dir/reviews.json" > "$out_dir/reviews.tsv"

files_count="$(jq 'length' "$out_dir/files.json")"
review_comments_count="$(jq 'length' "$out_dir/review_comments.json")"
issue_comments_count="$(jq 'length' "$out_dir/issue_comments.json")"
reviews_count="$(jq 'length' "$out_dir/reviews.json")"
commits_count="$(jq 'length' "$out_dir/commits.json")"

cat > "$out_dir/summary.txt" <<SUMMARY
owner=${owner}
repo=${repo}
pr=${pr}
fetched_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
files=${files_count}
review_comments=${review_comments_count}
issue_comments=${issue_comments_count}
reviews=${reviews_count}
commits=${commits_count}
out_dir=${out_dir}
SUMMARY

echo "Fetched PR review context successfully"
echo "  owner/repo: ${owner}/${repo}"
echo "  pr: ${pr}"
echo "  files: ${files_count}"
echo "  review comments: ${review_comments_count}"
echo "  issue comments: ${issue_comments_count}"
echo "  reviews: ${reviews_count}"
echo "  commits: ${commits_count}"
echo "  out dir: ${out_dir}"
