#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="pr-reviewer"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Support both layouts:
# 1) packed layout: <repo>/pr-reviewer/{SKILL.md,agents,scripts}
# 2) flat layout:   <repo>/{SKILL.md,agents,scripts}
if [[ -d "$SCRIPT_DIR/$SKILL_NAME" ]]; then
  SRC_DIR="$SCRIPT_DIR/$SKILL_NAME"
else
  SRC_DIR="$SCRIPT_DIR"
fi

usage() {
  cat <<USAGE
Install the ${SKILL_NAME} Codex skill.

Usage:
  ./install.sh [--dest <skills-dir>] [--link] [--force]

Options:
  --dest <skills-dir>  Destination skills directory.
                      Default: \$CODEX_HOME/skills if CODEX_HOME is set,
                      else ~/.config/qgenie-cli/agent/skills
  --link               Symlink skill directory instead of copying.
  --force              Replace existing destination skill directory.
  -h, --help           Show help.
USAGE
}

DEST_BASE=""
MODE="copy"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      DEST_BASE="${2:-}"
      shift 2
      ;;
    --link)
      MODE="link"
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$SRC_DIR/SKILL.md" ]]; then
  echo "Skill metadata not found: $SRC_DIR/SKILL.md" >&2
  exit 1
fi
if [[ ! -d "$SRC_DIR/agents" ]]; then
  echo "Missing agents directory: $SRC_DIR/agents" >&2
  exit 1
fi
if [[ ! -d "$SRC_DIR/scripts" ]]; then
  echo "Missing scripts directory: $SRC_DIR/scripts" >&2
  exit 1
fi

if [[ -z "$DEST_BASE" ]]; then
  if [[ -n "${CODEX_HOME:-}" ]]; then
    DEST_BASE="$CODEX_HOME/skills"
  else
    DEST_BASE="$HOME/.config/qgenie-cli/agent/skills"
  fi
fi

DEST_DIR="$DEST_BASE/$SKILL_NAME"
mkdir -p "$DEST_BASE"

if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$DEST_DIR"
  else
    echo "Destination exists: $DEST_DIR" >&2
    echo "Use --force to replace it." >&2
    exit 1
  fi
fi

if [[ "$MODE" == "link" ]]; then
  ln -s "$SRC_DIR" "$DEST_DIR"
  echo "Installed via symlink: $DEST_DIR -> $SRC_DIR"
else
  cp -a "$SRC_DIR" "$DEST_DIR"
  echo "Installed via copy: $DEST_DIR"
fi

echo "Done."
