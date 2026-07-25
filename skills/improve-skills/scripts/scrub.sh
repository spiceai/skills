#!/bin/bash
set -e

# Leak gate for the improve-skills weekly run.
#
# Scans the ADDED lines of the outgoing diff (and optionally a PR body) against
# the denylist and a URL allowlist. Exits non-zero on any finding.
#
# Only added lines are inspected, so pre-existing content never generates noise.
# This is a backstop, not a substitute for sourcing discipline: a clean scrub on
# content derived from an internal source is still a leak.
#
# Usage: bash scripts/scrub.sh [--base trunk] [--body FILE] [--paths PATHSPEC]

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="trunk"
BODY=""
PATHSPEC="."

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --paths) PATHSPEC="$2"; shift 2 ;;
    -h|--help) sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "Error: jq not found" >&2; exit 1; }

# Diff paths are always repo-relative, so run from the repo root to keep
# --paths and the exclude prefixes meaningful wherever this is invoked from.
case "$BODY" in ""|/*) ;; *) BODY="$PWD/$BODY" ;; esac
cd "$(git rev-parse --show-toplevel)" || { echo "Error: not in a git repo" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Build the pattern set --------------------------------------------------
# Patterns are matched against lower-cased content, so write them lower-case.
PATTERNS="$WORK/patterns.txt"
: > "$PATTERNS"

for f in "$SKILL_DIR/config/denylist.example.txt" "$SKILL_DIR/config/denylist.local.txt"; do
  [ -f "$f" ] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$f" >> "$PATTERNS" || true
done

# Derive patterns from the internal sources so private repo and org names are
# covered without ever being written into a committed file.
LOCAL_SOURCES="$SKILL_DIR/config/sources.local.yaml"
if [ -f "$LOCAL_SOURCES" ]; then
  awk '
    /^[a-z_]+:/ { section = $1; sub(/:$/, "", section) }
    section == "internal" && /repo:[[:space:]]*/ {
      sub(/^.*repo:[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, "")
      if ($0 != "") { print tolower($0); split($0, p, "/"); print tolower(p[1]) }
    }
  ' "$LOCAL_SOURCES" | sort -u >> "$PATTERNS"
fi

[ -s "$PATTERNS" ] || { echo "Error: no denylist patterns loaded" >&2; exit 1; }

# --- Collect added lines as file<TAB>line<TAB>content ------------------------
STREAM="$WORK/added.tsv"
: > "$STREAM"

# Added lines are collected from two places, because scanning only one leaves a
# silent hole: running before committing would otherwise report "clean" without
# having looked at the content about to be committed.
added_lines() {
  awk '
    /^\+\+\+ /  { file = substr($0, 7); next }
    /^@@ /      { match($0, /\+[0-9]+/); n = substr($0, RSTART+1, RLENGTH-1) + 0; next }
    /^\+/       { print file "\t" n "\t" substr($0, 2); n++ }
  '
}

if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  git diff --unified=0 "$BASE...HEAD" -- "$PATHSPEC" 2>/dev/null | added_lines >> "$STREAM"
else
  echo "Warning: base ref '$BASE' not found — committed changes not compared." >&2
fi

# Staged and unstaged changes, including intent-to-add new files.
git diff --unified=0 HEAD -- "$PATHSPEC" 2>/dev/null | added_lines >> "$STREAM"

# Untracked files git diff cannot see at all.
while IFS= read -r f; do
  [ -f "$f" ] || continue
  awk -v fn="$f" '{ print fn "\t" NR "\t" $0 }' "$f" >> "$STREAM"
done < <(git ls-files --others --exclude-standard --full-name -- "$PATHSPEC" 2>/dev/null)

sort -u -o "$STREAM" "$STREAM"

# Drop excluded paths. The PR body is never excluded.
EXCLUDE="$SKILL_DIR/config/scan-exclude.txt"
if [ -f "$EXCLUDE" ]; then
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$EXCLUDE" > "$WORK/exclude.txt" || true
  if [ -s "$WORK/exclude.txt" ]; then
    awk -F'\t' -v exfile="$WORK/exclude.txt" '
      BEGIN { ne = 0; while ((getline e < exfile) > 0) if (e != "") ex[++ne] = e }
      {
        if ($1 != "PR-BODY")
          for (i = 1; i <= ne; i++)
            if (index($1, ex[i]) == 1) next
        print
      }
    ' "$STREAM" > "$WORK/filtered.tsv"
    SKIPPED=$(( $(wc -l < "$STREAM") - $(wc -l < "$WORK/filtered.tsv") ))
    mv "$WORK/filtered.tsv" "$STREAM"
    [ "$SKIPPED" -gt 0 ] && echo "Skipped $SKIPPED line(s) under excluded paths (config/scan-exclude.txt)." >&2
  fi
fi

if [ -n "$BODY" ]; then
  [ -f "$BODY" ] || { echo "Error: body file not found: $BODY" >&2; exit 1; }
  awk '{ print "PR-BODY\t" NR "\t" $0 }' "$BODY" >> "$STREAM"
fi

LINES=$(wc -l < "$STREAM" | tr -d ' ')
echo "Scanning $LINES added line(s) against $(wc -l < "$PATTERNS" | tr -d ' ') pattern(s)." >&2

# --- Match ------------------------------------------------------------------
FINDINGS="$WORK/findings.tsv"
awk -F'\t' -v patfile="$PATTERNS" '
  BEGIN {
    np = 0
    while ((getline line < patfile) > 0) {
      if (line == "") continue
      # POSIX awk has no \b word boundary (some awks read it as backspace and
      # the pattern then silently never matches). Translate it to an explicit
      # non-word character; content is space-padded below so boundaries at the
      # start and end of a line still have a character to match.
      gsub(/\\b/, "[^a-z0-9]", line)
      pats[++np] = line
    }
  }
  {
    content = $3
    lc = " " tolower(content) " "
    for (i = 1; i <= np; i++) {
      if (lc ~ pats[i]) {
        printf "%s\t%s\t%s\t%s\n", $1, $2, pats[i], substr(content, 1, 200)
      }
    }
  }
' "$STREAM" > "$FINDINGS"

# --- URL allowlist ----------------------------------------------------------
ALLOWLIST="$SKILL_DIR/config/url-allowlist.txt"
if [ -f "$ALLOWLIST" ]; then
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$ALLOWLIST" > "$WORK/hosts.txt" || true
  awk -F'\t' -v hostfile="$WORK/hosts.txt" '
    BEGIN {
      nh = 0
      while ((getline h < hostfile) > 0) if (h != "") hosts[++nh] = tolower(h)
    }
    {
      content = $3
      rest = content
      # Parens and trailing punctuation are excluded so markdown links like
      # [docs](https://spiceai.org) do not capture the closing bracket as
      # part of the hostname.
      while (match(rest, /https?:\/\/[a-zA-Z0-9._~:\/?#@!$&*+;=%-]+/)) {
        url = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/[.,;:!?]+$/, "", url)
        host = url
        sub(/^https?:\/\//, "", host)
        sub(/[\/:?#].*$/, "", host)
        host = tolower(host)
        # Skip placeholders like <app-name> and bare single-label hosts; real
        # internal hostnames are caught by the denylist patterns instead.
        if (host == "" || host !~ /\./) continue
        ok = 0
        for (i = 1; i <= nh; i++) if (host == hosts[i] || host ~ ("\\." hosts[i] "$")) ok = 1
        if (!ok) printf "%s\t%s\t%s\t%s\n", $1, $2, "url-not-allowlisted:" host, url
      }
    }
  ' "$STREAM" >> "$FINDINGS"
fi

# --- Report -----------------------------------------------------------------
COUNT=$(wc -l < "$FINDINGS" | tr -d ' ')

jq -Rn --slurpfile _ /dev/null '[]' >/dev/null 2>&1 || true
awk -F'\t' '{ printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }' "$FINDINGS" \
  | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t"))
              | map({file: .[0], line: (.[1] | tonumber), pattern: .[2], text: .[3]})'

if [ "$COUNT" -gt 0 ]; then
  echo "" >&2
  echo "BLOCKED: $COUNT finding(s). Do not push." >&2
  echo "" >&2
  while IFS=$'\t' read -r file line pattern text; do
    echo "  $file:$line" >&2
    echo "    pattern: $pattern" >&2
    echo "    text:    $text" >&2
  done < "$FINDINGS"
  echo "" >&2
  echo "Remove the content at its source. A finding here usually means an" >&2
  echo "internal detail was used as content rather than as signal — deleting" >&2
  echo "the line without fixing the sourcing means it returns next week." >&2
  exit 1
fi

echo "Clean: no denylisted content in added lines." >&2
