#!/bin/bash
set -e

# Package the Spice.ai skills plugin into a distributable archive.
# Includes Claude, Cursor, Codex, and portable Agent Plugins manifests.
#
# Usage:
#   ./scripts/package_plugin.sh              # creates dist/skills-plugin-<version>.tar.gz
#   ./scripts/package_plugin.sh --output-dir /tmp

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"

if [ ! -f "$PLUGIN_JSON" ]; then
  echo "ERROR: .claude-plugin/plugin.json not found" >&2
  exit 1
fi

# Parse version and name from Claude plugin.json (source of truth for release version)
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

# Claude
mkdir -p "$STAGE_DIR/.claude-plugin"
cp "$PLUGIN_JSON" "$STAGE_DIR/.claude-plugin/"
[ -f "$ROOT/.claude-plugin/marketplace.json" ] && cp "$ROOT/.claude-plugin/marketplace.json" "$STAGE_DIR/.claude-plugin/"

# Cursor
if [ -d "$ROOT/.cursor-plugin" ]; then
  mkdir -p "$STAGE_DIR/.cursor-plugin"
  cp "$ROOT/.cursor-plugin/"*.json "$STAGE_DIR/.cursor-plugin/" 2>/dev/null || true
fi

# Codex compatibility
if [ -d "$ROOT/.codex-plugin" ]; then
  mkdir -p "$STAGE_DIR/.codex-plugin"
  cp "$ROOT/.codex-plugin/"*.json "$STAGE_DIR/.codex-plugin/" 2>/dev/null || true
fi

# Portable Agent Plugins root manifest
[ -f "$ROOT/plugin.json" ] && cp "$ROOT/plugin.json" "$STAGE_DIR/"

# Repo marketplace catalog (Codex / ChatGPT local marketplaces)
if [ -f "$ROOT/.agents/plugins/marketplace.json" ]; then
  mkdir -p "$STAGE_DIR/.agents/plugins"
  cp "$ROOT/.agents/plugins/marketplace.json" "$STAGE_DIR/.agents/plugins/"
fi

# Copy skills (excluding workspace dirs, evals results, __pycache__)
mkdir -p "$STAGE_DIR/skills"
for skill_dir in "$ROOT"/skills/*/; do
  skill_name=$(basename "$skill_dir")
  dest="$STAGE_DIR/skills/$skill_name"
  mkdir -p "$dest"

  [ -f "$skill_dir/SKILL.md" ] && cp "$skill_dir/SKILL.md" "$dest/"
  [ -d "$skill_dir/scripts" ] && cp -r "$skill_dir/scripts" "$dest/"
  [ -d "$skill_dir/references" ] && cp -r "$skill_dir/references" "$dest/"

  if [ -d "$skill_dir/config" ]; then
    mkdir -p "$dest/config"
    find "$skill_dir/config" -maxdepth 1 -type f ! -name '*.local.*' \
      -exec cp {} "$dest/config/" \;
  fi

  [ -d "$skill_dir/examples" ] && cp -r "$skill_dir/examples" "$dest/"
  [ -d "$skill_dir/evals" ] && cp -r "$skill_dir/evals" "$dest/"
done

# Copy top-level files
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$STAGE_DIR/"
[ -f "$ROOT/CLAUDE.md" ] && cp "$ROOT/CLAUDE.md" "$STAGE_DIR/"

for f in build_benchmark.py grade_eval.py; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$STAGE_DIR/"
done

ARCHIVE_PATH="$OUTPUT_DIR/${ARCHIVE_NAME}.tar.gz"
tar -czf "$ARCHIVE_PATH" -C "$STAGING" "$ARCHIVE_NAME"

rm -rf "$STAGING"

echo "Created $ARCHIVE_PATH" >&2
echo "$ARCHIVE_PATH"
