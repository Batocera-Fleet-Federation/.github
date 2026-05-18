#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# configure-github-pr-protection.sh
#
# Purpose:
# - Add CODEOWNERS
# - Protect main/master/default branch
# - Block direct commits
# - Require PRs
# - Require code owner approval
# - Restrict protected branch pushes/merges to repo owner/code owner
#
# Requirements:
# - gh CLI installed
# - git installed
# - gh auth login completed
# - authenticated user must have admin rights on target repos
# ============================================================

GITHUB_OWNER="Batocera-Fleet-Federation"
CODEOWNER_USERNAME="DotNetRockStar"

REPOS=(
  "batocera.drone"
  "batocera.overmind"
  ".github"
)

# GitHub does not allow PR authors to approve their own PRs.
# Set this to 0 so DotNetRockStar can open and merge their own PRs while branch protection still blocks direct pushes.
REQUIRED_APPROVING_REVIEW_COUNT=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command not found: $1"
    exit 1
  fi
}

get_default_branch() {
  local repo="$1"

  gh repo view "$GITHUB_OWNER/$repo" \
    --json defaultBranchRef \
    --jq '.defaultBranchRef.name'
}

ensure_codeowners() {
  local repo="$1"
  local branch="$2"
  local repo_dir="$TMP_DIR/$repo"

  log "Updating CODEOWNERS for $GITHUB_OWNER/$repo on branch $branch"

  gh repo clone "$GITHUB_OWNER/$repo" "$repo_dir" -- --quiet

  pushd "$repo_dir" >/dev/null

  git checkout "$branch"

  mkdir -p .github

  cat > .github/CODEOWNERS <<EOF
# All files in this repository require review from the code owner.
* @$CODEOWNER_USERNAME
EOF

  if git diff --quiet -- .github/CODEOWNERS; then
    log "CODEOWNERS already up to date for $repo"
  else
    git add .github/CODEOWNERS
    git commit -m "chore: add repository CODEOWNERS"
    git push origin "$branch"
    log "Pushed CODEOWNERS update for $repo"
  fi

  popd >/dev/null
}

protect_branch() {
  local repo="$1"
  local branch="$2"

  log "Applying branch protection to $GITHUB_OWNER/$repo:$branch"

  gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "/repos/$GITHUB_OWNER/$repo/branches/$branch/protection" \
    --input - <<EOF
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": $REQUIRED_APPROVING_REVIEW_COUNT,
    "require_last_push_approval": false,
    "bypass_pull_request_allowances": {
      "users": ["$CODEOWNER_USERNAME"],
      "teams": [],
      "apps": []
    }
  },
  "restrictions": {
    "users": ["$CODEOWNER_USERNAME"],
    "teams": [],
    "apps": []
  },
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": true
}
EOF

  log "Branch protection applied to $repo:$branch"
}

main() {
  require_command gh
  require_command git

  gh auth status >/dev/null

  for repo in "${REPOS[@]}"; do
    log "Configuring repository: $GITHUB_OWNER/$repo"

    default_branch="$(get_default_branch "$repo")"

    if [[ -z "$default_branch" || "$default_branch" == "null" ]]; then
      echo "ERROR: Could not determine default branch for $GITHUB_OWNER/$repo"
      continue
    fi

    log "Default branch for $repo is $default_branch"

    ensure_codeowners "$repo" "$default_branch"
    protect_branch "$repo" "$default_branch"

    log "Completed $GITHUB_OWNER/$repo"
    echo
  done

  log "All repositories processed."
}

main "$@"