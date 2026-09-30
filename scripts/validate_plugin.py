#!/usr/bin/env python3
"""Validate this repo's publishing contract, without network access or API keys."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = ["plugin.json"] + [
    f".{client}-plugin/plugin.json" for client in ("claude", "codex", "cursor", "grok")
]
CATALOGS = [
    ".claude-plugin/marketplace.json", ".cursor-plugin/marketplace.json",
    ".grok-plugin/marketplace.json", ".agents/plugins/marketplace.json",
    ".github/plugin/marketplace.json",
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def excluded(path):
    return any(
        part in {".private", "improve-skills", ".git", ".DS_Store", "__pycache__", ".audit", "evals", ".env"}
        or part.startswith(".env.") or ".local." in part
        or part.endswith((".pyc", ".pyo", "-workspace"))
        for part in PurePosixPath(path).parts
    )


def validate_source(root=ROOT):
    manifests = {p: json.loads((root / p).read_text()) for p in MANIFESTS}
    canonical = manifests["plugin.json"]
    name, version = canonical["name"], canonical["version"]
    require(name == "spiceai", "Public plugin name must remain spiceai")
    require(re.fullmatch(r"\d+\.\d+\.\d+", version), "Expected a runtime-aligned release version")
    for path, manifest in manifests.items():
        require((manifest.get("name"), manifest.get("version")) == (name, version), f"{path}: name/version mismatch")
    for path in CATALOGS:
        catalog = json.loads((root / path).read_text())
        require(catalog.get("name") == name, f"{path}: marketplace name mismatch")
        require(len(catalog["plugins"]) == 1, f"{path}: expected one public plugin")
        entry = catalog["plugins"][0]
        require(entry.get("name") == name and entry.get("version", version) == version, f"{path}: plugin identity mismatch")
        source = entry["source"]
        local = source in (".", "./") if isinstance(source, str) else (
            source.get("source", source.get("type")) == "local" and source.get("path") == "./"
        )
        require(local, f"{path}: use the current checkout, not an unpinned remote copy")

    interface = canonical["extensions"]["com.openai"]["interface"]
    require(interface == manifests[".codex-plugin/plugin.json"]["interface"], "OpenAI interface overlays disagree")
    for field in ("composerIcon", "logo"):
        path = PurePosixPath(interface[field])
        require(not path.is_absolute() and ".." not in path.parts, f"Invalid {field} path")
        require((root / path).is_file(), f"Missing {field}: {path}")
    require((root / "LICENSE").is_file(), "Missing distribution license")

    skills = sorted((root / "skills").glob("*/SKILL.md"))
    require(skills, "No public skills")
    require(not (root / "skills/improve-skills").exists(), "Private improve-skills must not be publicly discoverable")
    for path in skills:
        content = path.read_text()
        frontmatter = re.match(r"\A---\n(.*?)\n---(?:\n|$)", content, re.S)
        require(frontmatter, f"{path}: missing frontmatter")
        skill_name = re.search(r"^name:\s*([a-z0-9-]+)\s*$", frontmatter[1], re.M)
        require(skill_name and skill_name[1] == path.parent.name, f"{path}: skill name/directory mismatch")
        require(re.search(r"^description:\s*\S", frontmatter[1], re.M), f"{path}: missing description")
        require(len(content.splitlines()) < 500, f"{path}: exceeds skill line budget")
        # A narrow regression check for the installer pattern flagged in review.
        require(not re.search(r"install\.spiceai\.org|DownloadString|(?:curl|wget)[^\n]*\|\s*(?:/bin/)?(?:ba)?sh\b", content),
                f"{path}: remote installer execution must not return")

    # Symlinks can copy content from outside the reviewed source tree.
    for base in [root / "skills", root / "assets"] + [root / p for p in MANIFESTS + CATALOGS]:
        for path in [base] + (list(base.rglob("*")) if base.is_dir() else []):
            require(not path.is_symlink(), f"Payload symlink is not allowed: {path}")
    if (root / ".git").exists():
        tracked = subprocess.check_output(["git", "ls-files", "-z", "--", ".private"], cwd=root).decode().split("\0")
        require(not any(p and (root / p).exists() for p in tracked), "Private maintainer files must not be tracked")
    return canonical, [p.parent.name for p in skills]


def validate_archives(directory, root=ROOT):
    manifest, skills = validate_source(root)
    stem = f"{manifest['name']}-plugin-{manifest['version']}"
    with zipfile.ZipFile(directory / f"{stem}.zip") as archive:
        require(archive.testzip() is None, "ZIP integrity failure")
        infos = archive.infolist()
        require(len({i.filename for i in infos}) == len(infos), "Duplicate ZIP paths")
        require(all(stat.S_ISREG(i.external_attr >> 16) for i in infos), "ZIP must contain regular files only")
        files = {i.filename: archive.read(i) for i in infos}
        modes = {i.filename: (i.external_attr >> 16) & 0o777 for i in infos}
    with tarfile.open(directory / f"{stem}.tar.gz") as archive:
        members = archive.getmembers()
        require(all(m.isfile() or m.isdir() for m in members), "Tar contains a link or special file")
        require(len({m.name for m in members}) == len(members), "Duplicate tar paths")
        tar_files = {m.name: archive.extractfile(m).read() for m in members if m.isfile()}
        require(files == tar_files, "ZIP and tar contents differ")
        require(all(m.mode == modes[m.name] for m in members if m.isfile()), "Archive permissions differ")
    for name, content in files.items():
        path = PurePosixPath(name)
        require(path.parts[0] == stem and not path.is_absolute() and ".." not in path.parts, f"Unsafe archive path: {name}")
        relative = PurePosixPath(*path.parts[1:])
        require(not excluded(str(relative)), f"Private or development resource bundled: {name}")
        require((root / relative).read_bytes() == content, f"Stale packaged file: {name}")
        expected_mode = 0o755 if (root / relative).stat().st_mode & 0o111 else 0o644
        require(modes[name] == expected_mode, f"Executable permission lost: {name}")
    for path in MANIFESTS + CATALOGS + ["LICENSE", "README.md"]:
        require(f"{stem}/{path}" in files, f"Missing packaged metadata: {path}")
    packaged_skills = sorted(PurePosixPath(p).parent.name for p in files if p.endswith("/SKILL.md"))
    require(packaged_skills == skills, "Public skill set differs from archive")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-dir", type=Path)
    args = parser.parse_args()
    try:
        manifest, skills = validate_source()
        if args.archive_dir:
            validate_archives(args.archive_dir)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(f"Validation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"name": manifest["name"], "version": manifest["version"], "skills": len(skills), "valid": True}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
