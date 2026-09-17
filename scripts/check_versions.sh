#!/bin/bash
set -e

# Check that the skills stay aligned with the Spice runtime version they target.
#
#   1. Every plugin manifest carries the version in .claude-plugin/plugin.json.
#   2. Every Spice skill has a "## Version Compatibility" section naming the
#      target release line and the exact release it was checked against
#      (e.g. "Spice v2.3.x" and "v2.3.1" for plugin version 2.3.1).
#   3. No skill links trunk docs (spiceai.org/docs/next/), which match no release.
#
# improve-skills is exempt from 2 and 3: it maintains the skills, not Spice.
#
# Usage:
#   ./scripts/check_versions.sh     # prints a JSON summary; exits 1 on any problem

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 - <<'EOF'
import json
import pathlib
import re
import sys

root = pathlib.Path(".")
version = json.loads((root / ".claude-plugin/plugin.json").read_text())["version"]
line = ".".join(version.split(".")[:2])  # 2.3.1 -> 2.3
problems = []


def versions_in(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "version" and isinstance(value, str):
                yield value
            else:
                yield from versions_in(value)
    elif isinstance(node, list):
        for value in node:
            yield from versions_in(value)


manifests = [
    ".claude-plugin/marketplace.json",
    ".codex-plugin/plugin.json",
    ".cursor-plugin/plugin.json",
    ".cursor-plugin/marketplace.json",
    ".grok-plugin/plugin.json",
    ".grok-plugin/marketplace.json",
    "plugin.json",
]
for path in manifests:
    manifest = root / path
    if not manifest.exists():
        continue
    for found in versions_in(json.loads(manifest.read_text())):
        if found != version:
            problems.append(f"{path}: version {found} != {version}")

skills = sorted(p for p in (root / "skills").glob("*/SKILL.md") if p.parent.name != "improve-skills")
for skill in skills:
    text = skill.read_text()
    section = re.search(r"^## Version Compatibility\n(.*?)(?=^## )", text, re.S | re.M)
    if not section:
        problems.append(f"{skill}: missing '## Version Compatibility' section")
    else:
        if f"v{line}.x" not in section.group(1):
            problems.append(f"{skill}: Version Compatibility does not name Spice v{line}.x")
        if f"checked against v{version}" not in section.group(1):
            problems.append(f"{skill}: Version Compatibility is not checked against v{version}")
    if "spiceai.org/docs/next/" in text:
        problems.append(f"{skill}: links trunk docs (spiceai.org/docs/next/)")

for problem in problems:
    print(f"FAIL {problem}", file=sys.stderr)
print(f"Checked {len(skills)} skills against plugin version {version}", file=sys.stderr)
print(json.dumps({"version": version, "skills": len(skills), "problems": problems}, indent=2))
sys.exit(1 if problems else 0)
EOF
