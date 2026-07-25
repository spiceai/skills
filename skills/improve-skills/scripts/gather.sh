#!/bin/bash
set -e

# Collect audit signal for the weekly improve-skills run.
#
# Public content sources -> full release bodies (quotable, still must be cited).
# Internal sources       -> merged PR titles and labels only.
#
# Everything is written under --out (gitignored). Internal signal is written to
# files marked SIGNAL ONLY: read them to decide where to look, never copy their
# contents into a skill, commit message, or PR body.
#
# Usage: bash skills/improve-skills/scripts/gather.sh
#          [--out DIR] [--since YYYY-MM-DD] [--config FILE]
#          [--limit N] [--with-paths]

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=".audit"
OUT_SET=""
SINCE=""
CONFIG=""
LIMIT=200
WITH_PATHS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; OUT_SET=1; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --with-paths) WITH_PATHS=1; shift ;;
    -h|--help) sed -n '3,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v gh >/dev/null || { echo "Error: gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "Error: jq not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Error: gh not authenticated (run: gh auth login)" >&2; exit 1; }

[ -n "$OUT_SET" ] && case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
case "$CONFIG" in ""|/*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac
cd "$(git rev-parse --show-toplevel)" || { echo "Error: not in a git repo" >&2; exit 1; }

# --- Config ----------------------------------------------------------------
if [ -z "$CONFIG" ]; then
  if [ -f "$SKILL_DIR/config/sources.local.yaml" ]; then
    CONFIG="$SKILL_DIR/config/sources.local.yaml"
  else
    CONFIG="$SKILL_DIR/config/sources.example.yaml"
    echo "Note: no sources.local.yaml — running with public sources only." >&2
  fi
fi
[ -f "$CONFIG" ] || { echo "Error: config not found: $CONFIG" >&2; exit 1; }

# Minimal parse of the fixed sources.yaml shape. Emits "repo<TAB>role" for each
# entry in the requested top-level section; role defaults to the section name.
entries_in_section() {
  awk -v want="$1" '
    /^[a-z_]+:/ { section = $1; sub(/:$/, "", section) }
    section != want { next }
    /^[[:space:]]*-?[[:space:]]*repo:[[:space:]]*/ {
      if (repo != "") { print repo "\t" (role == "" ? want : role) }
      line = $0
      sub(/^[[:space:]]*-?[[:space:]]*repo:[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      repo = line; role = ""; next
    }
    /^[[:space:]]+role:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+role:[[:space:]]*/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      role = line
    }
    END { if (repo != "") print repo "\t" (role == "" ? want : role) }
  ' "$CONFIG"
}

# --- Window ----------------------------------------------------------------
STATE_FILE="$OUT_DIR/state.local.json"
if [ -z "$SINCE" ] && [ -f "$STATE_FILE" ]; then
  SINCE=$(jq -r '.last_audit_utc // empty' "$STATE_FILE")
fi
if [ -z "$SINCE" ]; then
  SINCE=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  echo "Note: no prior state — defaulting to a 7-day window." >&2
fi
case "$SINCE" in *T*) ;; *) SINCE="${SINCE}T00:00:00Z" ;; esac

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_DIR="$OUT_DIR/$(date -u +%Y-%m-%d)"
mkdir -p "$RUN_DIR/public" "$RUN_DIR/signal"

echo "Window: $SINCE -> $NOW" >&2

# Retry transient GitHub failures. A 502 from the GraphQL API must never be
# mistaken for "this source had no activity" — that would silently drop a whole
# repository from the audit.
gh_retry() {
  local attempt
  for attempt in 1 2 3; do
    if "$@"; then return 0; fi
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  return 1
}

FAILED=()

# --- Public: shipped releases only (role: content) --------------------------
PUBLIC_TAGS=()
while IFS=$'\t' read -r repo role; do
  [ -z "$repo" ] && continue
  if [ "$role" != "content" ]; then
    echo "Skipping releases for $repo (role: $role — corroboration source, read on demand)." >&2
    continue
  fi
  echo "Fetching published releases: $repo" >&2
  # The isPrerelease flag is set by hand and is routinely wrong — v2.0.0-rc.*
  # tags come back with isPrerelease false. Judge by the tag itself as well, or
  # release-candidate work gets treated as shipped.
  if ! tags=$(gh_retry gh release list --repo "$repo" --limit 50 \
      --json tagName,publishedAt,isPrerelease,isDraft \
      --jq ".[] | select(.isPrerelease == false and .isDraft == false) \
            | select(.tagName | test(\"-(rc|alpha|beta|pre|dev)\"; \"i\") | not) \
            | select(.publishedAt > \"$SINCE\") | .tagName"); then
    echo "  FAILED to list releases for $repo" >&2
    FAILED+=("$repo (releases)")
    continue
  fi
  for tag in $tags; do
    safe="${repo//\//_}_${tag//\//_}"
    if gh_retry gh release view "$tag" --repo "$repo" \
        --json tagName,publishedAt,url,body > "$RUN_DIR/public/$safe.json"; then
      PUBLIC_TAGS+=("$repo@$tag")
      echo "  shipped: $tag" >&2
    else
      echo "  FAILED to fetch release body for $repo@$tag" >&2
      FAILED+=("$repo@$tag (body)")
    fi
  done
done < <(entries_in_section public)

if [ ${#PUBLIC_TAGS[@]} -eq 0 ]; then
  echo "No releases shipped in this window. Deprecation sweeps and doc-link checks still apply." >&2
fi

# --- Internal: signal only --------------------------------------------------
# Titles and labels are cheap to fetch. Changed paths (--with-paths) require the
# `files` field, which makes the GraphQL query expensive enough to 502 on active
# repositories, so it is opt-in.
FIELDS="number,title,labels,mergedAt"
PATH_EXPR=""
if [ -n "$WITH_PATHS" ]; then
  FIELDS="$FIELDS,files"
  PATH_EXPR=' + "  {" + ([(.files // [])[].path | split("/")[0:2] | join("/")] | unique | join(", ")) + "}"'
fi

SIGNAL_COUNT=0
while IFS=$'\t' read -r repo role; do
  [ -z "$repo" ] && continue
  echo "Fetching signal (titles/labels only): $repo" >&2
  safe="${repo//\//_}"
  dest="$RUN_DIR/signal/$safe.md"
  {
    echo "# SIGNAL ONLY — never copy this content forward"
    echo
    echo "Use this to decide WHICH skill to examine and WHERE to look in public"
    echo "sources. Every fact that reaches a SKILL.md, commit, or PR body must be"
    echo "re-derived from a public source and cited. See references/disclosure-policy.md."
    echo
  } > "$dest"

  if ! raw=$(gh_retry gh pr list --repo "$repo" --state merged --limit "$LIMIT" --json "$FIELDS"); then
    echo "  FAILED — source not collected (this is NOT 'no activity')" >&2
    echo "_Collection failed for this source; treat its coverage as unknown._" >> "$dest"
    FAILED+=("$repo (signal)")
    continue
  fi

  echo "$raw" | jq -r --arg since "$SINCE" \
    "[.[] | select(.mergedAt > \$since)] | .[] | \"- \" + .title
      + \"  [\" + ([(.labels // [])[].name] | join(\",\")) + \"]\"$PATH_EXPR" >> "$dest"

  n=$(grep -c '^- ' "$dest" || true)
  fetched=$(echo "$raw" | jq 'length')
  oldest=$(echo "$raw" | jq -r '[.[].mergedAt] | min // empty')
  SIGNAL_COUNT=$((SIGNAL_COUNT + n))
  echo "  $n merged PRs in window" >&2

  # Saturation: the fetch hit its cap and the oldest PR retrieved is still newer
  # than the window start, so older in-window merges were never seen.
  if [ "$fetched" -ge "$LIMIT" ] && [ -n "$oldest" ] && [[ "$oldest" > "$SINCE" ]]; then
    echo "  WARNING: hit --limit $LIMIT; merges before $oldest were not fetched." >&2
    echo "           Re-run with a larger --limit or a narrower --since." >&2
    echo "" >> "$dest"
    echo "_Truncated at $LIMIT PRs; merges before $oldest were not collected._" >> "$dest"
    FAILED+=("$repo (truncated at $LIMIT)")
  fi
done < <(entries_in_section internal)

# --- Manifest ---------------------------------------------------------------
jq -n \
  --arg since "$SINCE" \
  --arg until "$NOW" \
  --arg run_dir "$RUN_DIR" \
  --arg config "$CONFIG" \
  --argjson signal_count "$SIGNAL_COUNT" \
  --argjson public_tags "$(printf '%s\n' "${PUBLIC_TAGS[@]+"${PUBLIC_TAGS[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" \
  --argjson incomplete "$(printf '%s\n' "${FAILED[@]+"${FAILED[@]}"}" | jq -R . | jq -s 'map(select(length > 0))')" \
  '{window: {since: $since, until: $until},
    run_dir: $run_dir,
    config: $config,
    shipped_releases: $public_tags,
    internal_signal_items: $signal_count,
    incomplete: $incomplete,
    complete: ($incomplete | length == 0),
    next_state: {last_audit_utc: $until}}'

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "" >&2
  echo "Coverage is INCOMPLETE for ${#FAILED[@]} source(s). Say so in the run summary" >&2
  echo "and do not advance the state high-water mark, or the gap becomes permanent." >&2
fi

echo "Wrote $RUN_DIR. Update $STATE_FILE with next_state once the run completes." >&2
