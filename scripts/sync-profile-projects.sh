#!/usr/bin/env bash
# sync-profile-projects.sh
# ─────────────────────────────────────────────────────────────
# Fetches all public repos from Astolfo3's GitHub account,
# checks the projects table in README.md, and adds any new
# projects as rows.
#
# Usage:
#   export GH_TOKEN="ghp_..."
#   ./scripts/sync-profile-projects.sh
#
# Or pass token as argument:
#   ./scripts/sync-profile-projects.sh ghp_...
# ─────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
README_FILE="$REPO_ROOT/README.md"
GITHUB_USER="Astolfo3"

# ── Get token ───────────────────────────────────────────────
TOKEN="${1:-${GH_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "🌸 need a GitHub token! pass it as an arg or set GH_TOKEN env var"
  echo "   usage: $0 ghp_..."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "🌸 jq is required — install it first!"
  exit 1
fi

# ── Fetch all repos ─────────────────────────────────────────
echo "🌸 fetching repos for $GITHUB_USER..."

REPOS_JSON="$(curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/users/$GITHUB_USER/repos?per_page=100&sort=updated&direction=desc")"

if echo "$REPOS_JSON" | jq -e 'if type=="object" then .message else false end' &>/dev/null; then
  MSG="$(echo "$REPOS_JSON" | jq -r '.message')"
  echo "🌸 GitHub API error: $MSG"
  exit 1
fi

REPO_COUNT="$(echo "$REPOS_JSON" | jq 'length')"

# ── Read existing project names from README table ───────────
echo "🌸 scanning projects table in README.md..."

# Use grep with extended regex to extract project names from table rows
# Rows look like: | 🌸[Bloom](https://github.com/Astolfo3/Bloom) | active | ...
declare -a EXISTING_PROJECTS=()
TABLE_PATTERN='\|.*\[([a-zA-Z0-9_-]+)\]\(https://github.com/'

while IFS= read -r line; do
  if [[ "$line" =~ $TABLE_PATTERN ]]; then
    EXISTING_PROJECTS+=("${BASH_REMATCH[1]}")
  fi
done < "$README_FILE"

echo "  found ${#EXISTING_PROJECTS[@]} existing project(s) in the table"

# ── Helper to join array by delimiter ───────────────────────
join_by() {
  local d="$1"
  shift
  local out=""
  for item in "$@"; do
    if [[ -z "$out" ]]; then
      out="$item"
    else
      out="$out$d$item"
    fi
  done
  echo "$out"
}

EXISTING_JOINED="$(join_by "|" "${EXISTING_PROJECTS[@]}")"

# ── Default description for repos ───────────────────────────
make_description() {
  local lang="$1"
  local name="$2"
  case "${name,,}" in
    *bloom*)     echo "A cute Rust project making terminals pastel and performant" ;;
    *pinkfetch*) echo "A cute system info fetcher, pastel style" ;;
    *dotfiles*)  echo "My dotfiles — all pink, all pretty" ;;
    *nvim*|*vim*|*neovim*) echo "Neovim config — soft pink pastel edition" ;;
    *)          
      if [[ -n "$lang" && "$lang" != "null" ]]; then
        echo "A $lang project"
      else
        echo "A cute project"
      fi
      ;;
  esac
}

# ── Determine status label ──────────────────────────────────
infer_status_label() {
  local archived="$1"
  local disabled="$2"
  local pushed="$3"

  if [[ "$archived" == "true" || "$disabled" == "true" ]]; then
    echo "done"
    return
  fi

  local now
  now="$(date +%s)"
  local pushed_ts
  pushed_ts="$(date -d "$pushed" +%s 2>/dev/null || echo 0)"
  local three_months=$((90 * 24 * 3600))

  if [[ $((now - pushed_ts)) -lt $three_months ]]; then
    echo "active"
  else
    echo "on hold"
  fi
}

# ── Process repos ───────────────────────────────────────────
NEW_COUNT=0
ROWS_TO_ADD=""

for ((i = 0; i < REPO_COUNT; i++)); do
  name="$(echo "$REPOS_JSON" | jq -r ".[$i].name")"
  desc="$(echo "$REPOS_JSON" | jq -r "(.[$i].description // \"\")")"
  lang="$(echo "$REPOS_JSON" | jq -r "(.[$i].language // \"\")")"
  pushed="$(echo "$REPOS_JSON" | jq -r "(.[$i].pushed_at // \"\")")"
  archived="$(echo "$REPOS_JSON" | jq -r "(.[$i].archived | tostring)")"
  disabled="$(echo "$REPOS_JSON" | jq -r "(.[$i].disabled | tostring)")"

  # Skip profile repos
  if [[ "$name" == "Astolfo" || "$name" == "Astolfo3" ]]; then
    continue
  fi

  # Check if already in the table
  if echo "$EXISTING_JOINED" | grep -q "$name"; then
    continue
  fi

  echo "  ➕ new project: $name"

  # Pick description
  if [[ -z "$desc" || "$desc" == "null" ]]; then
    desc="$(make_description "$lang" "$name")"
  fi

  status="$(infer_status_label "$archived" "$disabled" "$pushed")"

  # Build the markdown table row
  row="| 🌸[$name](https://github.com/$GITHUB_USER/$name) | $status | $desc |"
  if [[ -z "$ROWS_TO_ADD" ]]; then
    ROWS_TO_ADD="$row"
  else
    ROWS_TO_ADD="$ROWS_TO_ADD"$'\n'"$row"
  fi
  NEW_COUNT=$((NEW_COUNT + 1))
done

if [[ $NEW_COUNT -eq 0 ]]; then
  echo "🌸 no new projects found — everything's up to date!"
  exit 0
fi

# ── Insert new rows into the README table ───────────────────
echo "🌸 adding $NEW_COUNT new row(s) to the projects table..."

# Find the separator line of the table: |---|---|---|
SEP_LINE="$(grep -n '^|[-]\+|[-]\+|[-]\+|$' "$README_FILE" | head -1 | cut -d: -f1)"

if [[ -z "$SEP_LINE" ]]; then
  echo "🌸 couldn't find the projects table separator — is the table intact?"
  exit 1
fi

# Find the blank line after the last table row (end of table)
# Start searching from the separator line
TABLE_END="$(tail -n +$((SEP_LINE + 1)) "$README_FILE" | grep -n '^$' | head -1 | cut -d: -f1)"

if [[ -z "$TABLE_END" ]]; then
  # No blank line found, insert after separator
  INSERT_BEFORE=$((SEP_LINE + 1))
else
  INSERT_BEFORE=$((SEP_LINE + TABLE_END))
fi

# Use awk to insert rows before the blank line that ends the table
awk -v insert_before="$INSERT_BEFORE" -v new_rows="$ROWS_TO_ADD" '
{
  if (NR == insert_before) {
    printf "%s\n", new_rows
  }
  print
}' "$README_FILE" > "$README_FILE.tmp"
mv "$README_FILE.tmp" "$README_FILE"

echo "🌸 README.md updated with $NEW_COUNT new project(s)!"
