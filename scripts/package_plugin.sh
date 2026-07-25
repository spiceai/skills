#!/bin/bash
set -e

# Package the Spice.ai Claude plugin into a distributable archive.
#
# Usage:
#   ./scripts/package_plugin.sh              # creates dist/spiceai-plugin-<version>.tar.gz
#   ./scripts/package_plugin.sh --output-dir /tmp

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"

if [ ! -f "$PLUGIN_JSON" ]; then
  echo "ERROR: .claude-plugin/plugin.json not found" >&2
  exit 1
fi

# Parse version and name from plugin.json
VERSION=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])")
NAME=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['name'])")

# Parse args
OUTPUT_DIR="$ROOT/dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

ARCHIVE_NAME="${NAME}-plugin-${VERSION}"
STAGING="$(mktemp -d)"
STAGE_DIR="$STAGING/$ARCHIVE_NAME"

echo "Packaging $NAME plugin v$VERSION..." >&2

# Copy plugin structure
mkdir -p "$STAGE_DIR/.claude-plugin"
cp "$PLUGIN_JSON" "$STAGE_DIR/.claude-plugin/"

# Copy skills (excluding workspace dirs, evals results, __pycache__)
mkdir -p "$STAGE_DIR/skills"
for skill_dir in "$ROOT"/skills/*/; do
  skill_name=$(basename "$skill_dir")
  dest="$STAGE_DIR/skills/$skill_name"
  mkdir -p "$dest"

  # Copy SKILL.md
  [ -f "$skill_dir/SKILL.md" ] && cp "$skill_dir/SKILL.md" "$dest/"

  # Copy scripts/ if present
  [ -d "$skill_dir/scripts" ] && cp -r "$skill_dir/scripts" "$dest/"

  # Copy references/ if present
  [ -d "$skill_dir/references" ] && cp -r "$skill_dir/references" "$dest/"

  # Copy config/ if present, excluding *.local.* overrides. Those are gitignored
  # because they can hold private source lists and customer names; bundling them
  # into a distributable archive would publish exactly what they exist to keep out.
  if [ -d "$skill_dir/config" ]; then
    mkdir -p "$dest/config"
    find "$skill_dir/config" -maxdepth 1 -type f ! -name '*.local.*' \
      -exec cp {} "$dest/config/" \;
  fi

  # Copy examples/ if present
  [ -d "$skill_dir/examples" ] && cp -r "$skill_dir/examples" "$dest/"

  # Copy evals/ if present
  [ -d "$skill_dir/evals" ] && cp -r "$skill_dir/evals" "$dest/"
done

# Copy top-level files
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$STAGE_DIR/"
[ -f "$ROOT/CLAUDE.md" ] && cp "$ROOT/CLAUDE.md" "$STAGE_DIR/"

# Copy eval infrastructure
for f in build_benchmark.py grade_eval.py; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$STAGE_DIR/"
done

# Create archive
ARCHIVE_PATH="$OUTPUT_DIR/${ARCHIVE_NAME}.tar.gz"
tar -czf "$ARCHIVE_PATH" -C "$STAGING" "$ARCHIVE_NAME"

# Cleanup
rm -rf "$STAGING"

echo "Created $ARCHIVE_PATH" >&2
echo "$ARCHIVE_PATH"
