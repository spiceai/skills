#!/usr/bin/env python3
"""Attach the prepared artifacts to GitHub; create a draft if no release exists."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from validate_plugin import ROOT, require, validate_archives, validate_source

START = "<!-- spiceai-marketplace-release:start -->"
END = "<!-- spiceai-marketplace-release:end -->"


def merge_notes(existing, generated):
    """Keep manually authored release notes and replace only our managed block."""
    if START in existing or END in existing:
        require(existing.count(START) == existing.count(END) == 1, "Ambiguous managed release-note markers")
        begin, end = existing.index(START), existing.index(END) + len(END)
        require(begin < end - len(END), "Reversed release-note markers")
        return existing[:begin] + generated.strip() + existing[end:]
    return existing.rstrip() + ("\n\n" if existing.strip() else "") + generated.strip() + "\n"


def publish(directory):
    manifest, _ = validate_source()
    name, version = manifest["name"], manifest["version"]
    metadata = json.loads((directory / f"{name}-release-{version}.json").read_text())
    require(not metadata["preview"], "Cannot publish a local preview")
    tag, repository = metadata["tag"], metadata["repository"]
    require(tag == f"v{version}" and metadata["name"] == name and metadata["version"] == version, "Release metadata does not match source")
    require(manifest["repository"] == f"https://github.com/{repository}", "Release repository mismatch")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    pinned = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], cwd=ROOT, text=True).strip()
    require(head == pinned == metadata["commit"], "Release commit/tag mismatch")
    require(not subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT), "Release checkout is dirty")
    validate_archives(directory)
    assets = metadata["assets"]
    require(assets and len(set(assets)) == len(assets), "Missing or duplicate release assets")
    for asset in assets:
        require(Path(asset).name == asset and (directory / asset).is_file(), f"Invalid asset: {asset}")
    checksum = f"{name}-plugin-{version}-SHA256SUMS.txt"
    lines = (directory / checksum).read_text().splitlines()
    sums = dict(line.split("  ", 1)[::-1] for line in lines)
    require(set(sums) == set(assets) - {checksum}, "Incomplete release checksums")
    for asset, digest in sums.items():
        require(hashlib.sha256((directory / asset).read_bytes()).hexdigest() == digest, f"Checksum mismatch: {asset}")
    require(metadata["submission_guide"] in assets, "Submission guide must be a release asset")
    generated = (directory / metadata["submission_guide"]).read_text()
    remote = subprocess.check_output(["gh", "api", f"repos/{repository}/commits/{tag}", "--jq", ".sha"], text=True).strip()
    require(remote == head, "Public release tag does not match the packaged commit")
    release = subprocess.run(["gh", "api", f"repos/{repository}/releases/tags/{tag}"], capture_output=True, text=True)
    command = ["gh", "release"]
    with tempfile.TemporaryDirectory() as tmp:
        notes = Path(tmp) / "release-notes.md"
        if release.returncode:
            require("HTTP 404" in release.stderr, f"Cannot read GitHub release: {release.stderr.strip()}")
            notes.write_text(generated)
            subprocess.run(command + ["create", tag, "--repo", repository, "--verify-tag", "--draft",
                                      "--title", f"{name} {tag}", "--notes-file", str(notes),
                                      *[str(directory / a) for a in assets]], check=True)
            status = "draft_created"
        else:
            notes.write_text(merge_notes(json.loads(release.stdout).get("body") or "", generated))
            subprocess.run(command + ["upload", tag, "--repo", repository, "--clobber",
                                      *[str(directory / a) for a in assets]], check=True)
            subprocess.run(command + ["edit", tag, "--repo", repository, "--notes-file", str(notes)], check=True)
            status = "assets_and_notes_updated"
    print(json.dumps({"tag": tag, "status": status, "external_marketplaces": "not submitted"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    try:
        publish(args.directory.resolve())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release upload failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
