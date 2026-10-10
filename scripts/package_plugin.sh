#!/bin/bash
set -e

# Package the Spice.ai skills plugin into distributable ZIP and tar.gz archives.
# Includes Claude, Cursor, Codex, Grok, and portable Agent Plugins manifests.
#
# Usage:
#   ./scripts/package_plugin.sh              # creates both archives in dist/
#   ./scripts/package_plugin.sh --output-dir /tmp

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"

python3 "$ROOT/scripts/validate_plugin.py" >&2

if [ ! -f "$PLUGIN_JSON" ]; then
  echo "ERROR: .claude-plugin/plugin.json not found" >&2
  exit 1
fi

# Parse version and name from Claude plugin.json (source of truth for release version)
VERSION=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN_JSON")
NAME=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$PLUGIN_JSON")

# Parse args
OUTPUT_DIR="$ROOT/dist"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: --output-dir requires a path" >&2
        exit 1
      fi
      OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"

ARCHIVE_NAME="${NAME}-plugin-${VERSION}"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
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

# Grok Build
if [ -d "$ROOT/.grok-plugin" ]; then
  mkdir -p "$STAGE_DIR/.grok-plugin"
  cp "$ROOT/.grok-plugin/"*.json "$STAGE_DIR/.grok-plugin/" 2>/dev/null || true
fi

# Portable Agent Plugins root manifest
[ -f "$ROOT/plugin.json" ] && cp "$ROOT/plugin.json" "$STAGE_DIR/"

# MCP servers: .mcp.json for Claude Code, mcp.json for Agent Plugins clients (Codex, Cursor)
for mcp in .mcp.json mcp.json; do
  [ -f "$ROOT/$mcp" ] && cp "$ROOT/$mcp" "$STAGE_DIR/"
done

# Listing icons referenced by the OpenAI manifests.
[ -d "$ROOT/assets" ] && cp -r "$ROOT/assets" "$STAGE_DIR/"

# Repo marketplace catalog (Codex / ChatGPT local marketplaces)
if [ -f "$ROOT/.agents/plugins/marketplace.json" ]; then
  mkdir -p "$STAGE_DIR/.agents/plugins"
  cp "$ROOT/.agents/plugins/marketplace.json" "$STAGE_DIR/.agents/plugins/"
fi

# GitHub Copilot marketplace (do not bundle GitHub Actions workflows).
mkdir -p "$STAGE_DIR/.github/plugin"
cp "$ROOT/.github/plugin/marketplace.json" "$STAGE_DIR/.github/plugin/"

# Copy runtime skill resources; evals remain repository development tooling.
mkdir -p "$STAGE_DIR/skills"
for skill_dir in "$ROOT"/skills/*/; do
  skill_name=$(basename "$skill_dir")
  # Private maintenance workflows must never ship, even if restored here locally.
  [ "$skill_name" = "improve-skills" ] && continue
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
done

# Copy top-level files
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$STAGE_DIR/"
[ -f "$ROOT/AGENTS.md" ] && cp "$ROOT/AGENTS.md" "$STAGE_DIR/"
cp "$ROOT/LICENSE" "$STAGE_DIR/"

# Strip local configuration and generated files from every copied directory.
# Both formats use exactly the same staged contents; ZIP is used by OpenAI.
python3 - "$STAGE_DIR" "$OUTPUT_DIR" <<'PY'
import json
import datetime
import gzip
import os
import pathlib
import shutil
import sys
import tarfile
import zipfile

stage = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2]).resolve()
for path in sorted(stage.rglob("*"), reverse=True):
    if (path.name in {".private", "improve-skills", ".git", ".DS_Store", "__pycache__", ".audit", "evals", ".env"}
            or path.name.startswith(".env.")
            or ".local." in path.name
            or path.name.endswith((".pyc", ".pyo", "-workspace"))):
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()

tar_path = output / f"{stage.name}.tar.gz"
zip_path = output / f"{stage.name}.zip"
# Fixed timestamps and owner IDs make identical source trees produce identical
# bytes, including when a published release workflow is rerun on another host.
epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "315532800"))  # 1980-01-01
def normalize(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = epoch
    info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
    info.pax_headers = {}
    return info

with tar_path.open("wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=epoch) as gz:
    with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as archive:
        archive.add(stage, arcname=stage.name, filter=normalize)
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(stage.rglob("*")):
        if path.is_file():
            info = zipfile.ZipInfo(str(path.relative_to(stage.parent)))
            info.date_time = datetime.datetime.fromtimestamp(max(epoch, 315532800), datetime.timezone.utc).timetuple()[:6]
            info.create_system = 3
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())

print(f"Created {zip_path} and {tar_path}", file=sys.stderr)
print(json.dumps({"zip": str(zip_path), "tar_gz": str(tar_path)}))
PY
