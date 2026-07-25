#!/bin/bash
set -e

# Check every external link in the skills for rot.
#
# Docs get reorganized between releases, so a skill that pointed at a valid page
# last month can now send users to a 404. This is the cheapest staleness signal
# available and the most useful thing to run in a week where nothing shipped.
#
# Usage: bash skills/improve-skills/scripts/linkcheck.sh [--paths skills]

PATHSPEC="skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --paths) PATHSPEC="$2"; shift 2 ;;
    -h|--help) sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "Error: jq not found" >&2; exit 1; }
cd "$(git rev-parse --show-toplevel)" || { echo "Error: not in a git repo" >&2; exit 1; }

# Collect unique URLs, dropping placeholders and loopback examples.
URLS=$(grep -rhoE 'https?://[^ )"`>,<]+' "$PATHSPEC" --include='*.md' 2>/dev/null \
  | sed -E 's/[.,;:!?]+$//' \
  | grep -vE '^https?://(localhost|127\.0\.0\.1|0\.0\.0\.0)' \
  | grep -vE '(example\.com|example\.org|<|\$\{|YOUR_|my-workspace)' \
  | grep -E '^https?://[^/]+\.[^/]' \
  | grep -vE '^https?://api\.|/v[0-9]+(/|$)' \
  | sort -u)

TOTAL=$(printf '%s\n' "$URLS" | grep -c . || true)
echo "Checking $TOTAL unique URL(s)..." >&2

BROKEN="[]"
n=0
while IFS= read -r url; do
  [ -z "$url" ] && continue
  n=$((n + 1))
  code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 20 \
           -A 'spiceai-skills-linkcheck' "$url" 2>/dev/null || true)
  code="${code: -3}"; code="${code:-000}"
  # 000 is a transport failure (DNS, TLS, timeout); retry once before believing it.
  if [ "$code" = "000" ]; then
    sleep 2
    code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 20 \
             -A 'spiceai-skills-linkcheck' "$url" 2>/dev/null || true)
  code="${code: -3}"; code="${code:-000}"
  fi
  case "$code" in
    2*|3*) ;;
    # 401/403 usually mean bot protection, and 405 means the URL exists but does
    # not answer GET. Neither is rot — report them separately so they are not
    # mistaken for links that need editing.
    401|403|405) echo "  [$code reachable, not GET-able] $url" >&2 ;;
    *)
      echo "  [$code BROKEN] $url" >&2
      where=$(grep -rl -- "$url" "$PATHSPEC" --include='*.md' 2>/dev/null | tr '\n' ' ')
      BROKEN=$(printf '%s' "$BROKEN" | jq --arg u "$url" --arg c "$code" --arg f "$where" \
                 '. + [{url: $u, status: $c, files: ($f | split(" ") | map(select(length > 0)))}]')
      ;;
  esac
done <<< "$URLS"

printf '%s' "$BROKEN" | jq --argjson checked "$n" '{checked: $checked, broken: .}'

COUNT=$(printf '%s' "$BROKEN" | jq 'length')
if [ "$COUNT" -gt 0 ]; then
  echo "" >&2
  echo "$COUNT broken link(s). Find where the page moved and cite the new URL;" >&2
  echo "a link that 404s often means the feature itself was renamed or removed." >&2
fi
