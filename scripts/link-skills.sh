#!/usr/bin/env bash
#
# link-skills.sh — surface every sub-repo Claude skill at the federation root.
#
# Claude Code only discovers skills in <cwd>/.claude/skills; it does not recurse
# into sub-repo .claude/skills dirs. This script scans every sub-repo for skills
# (any <root>/<repo>/.claude/skills/<skill>/) and creates a relative symlink for
# each one under <root>/.claude/skills/ so they are all discoverable when Claude
# is launched from the federation root.
#
# The source of truth stays in each repo; the root just holds links. Run it again
# any time you add a skill to a repo — it is idempotent.
#
# Usage:
#   .github/scripts/link-skills.sh                 # create / refresh links
#   .github/scripts/link-skills.sh --delete-links  # remove the links it created
#
set -euo pipefail

# Repo root = two levels up from this script (.github/scripts/ -> root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEST="$ROOT/.claude/skills"

DELETE=0
case "${1:-}" in
  --delete-links) DELETE=1 ;;
  "")             ;;
  *) echo "Usage: $(basename "$0") [--delete-links]" >&2; exit 2 ;;
esac

if [[ "$DELETE" -eq 1 ]]; then
  removed=0
  if [[ -d "$DEST" ]]; then
    # Only remove symlinks that point at a sub-repo skill — never real dirs.
    while IFS= read -r link; do
      target="$(readlink "$link")"
      if [[ "$target" == *"/.claude/skills/"* ]]; then
        rm "$link"
        echo "removed  $(basename "$link")"
        removed=$((removed + 1))
      fi
    done < <(find "$DEST" -maxdepth 1 -type l)
  fi
  echo "Done. Removed $removed skill link(s)."
  exit 0
fi

mkdir -p "$DEST"

# Find every skill dir: <root>/<repo>/.claude/skills/<skill>.
# mindepth/maxdepth 4 (relative to ROOT) targets the skill dirs exactly and
# excludes the root's own .claude/skills (depth 3). -path matches dot-dirs too.
created=0
while IFS= read -r src; do
  name="$(basename "$src")"
  rel="${src#"$ROOT"/}"                       # <repo>/.claude/skills/<skill>
  link="$DEST/$name"

  # Skip if a real (non-symlink) dir already owns this name.
  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "skip     $name (a real directory exists at the root, not replacing)" >&2
    continue
  fi
  # Warn on cross-repo name collisions.
  if [[ -L "$link" ]]; then
    existing="$(readlink "$link")"
    if [[ "$existing" != "../../$rel" ]]; then
      echo "warn     $name already links to $existing — overwriting with ../../$rel" >&2
    fi
  fi

  ln -sfn "../../$rel" "$link"
  echo "linked   $name -> ../../$rel"
  created=$((created + 1))
done < <(find "$ROOT" -mindepth 4 -maxdepth 4 -type d -path "*/.claude/skills/*" | sort)

echo "Done. Linked $created skill(s) into $DEST"
echo "Restart Claude Code at the federation root for the skills to be discovered."
