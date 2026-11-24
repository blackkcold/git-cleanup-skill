#!/usr/bin/env bash
# Install the git-cleanup skill into the OpenCode skills directory.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_ROOT="${OPENCODE_SKILLS_DIR:-$HOME/.config/opencode/skills}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dest <dir>]

  --dest <dir>   install into <dir>/git-cleanup
                 (default: $OPENCODE_SKILLS_DIR or ~/.config/opencode/skills)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST_ROOT="${2:?missing value for --dest}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

DEST="$DEST_ROOT/git-cleanup"
mkdir -p "$DEST/scripts" "$DEST/references"
cp "$SRC/SKILL.md" "$DEST/SKILL.md"
cp "$SRC/scripts/scan.sh" "$DEST/scripts/scan.sh"
cp "$SRC/references/rationale.md" "$DEST/references/rationale.md"
chmod +x "$DEST/scripts/scan.sh"

printf 'Installed git-cleanup -> %s\n' "$DEST"
printf 'Restart the host so it re-reads the skills directory.\n'
