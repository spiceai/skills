#!/usr/bin/env python3
"""Build a verified release and marketplace handoff; --preview never certifies a tag."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from validate_plugin import ROOT, require, validate_archives, validate_source


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def prepare(output, tag=None, preview=False):
    manifest, skills = validate_source()
    name, version = manifest["name"], manifest["version"]
    tag = tag or f"v{version}"
    require(tag == f"v{version}", f"Release tag {tag} must match manifest version v{version}")
    commit = git("rev-parse", "HEAD")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "Expected a full commit SHA")
    if not preview:
        require(not git("status", "--porcelain", "--untracked-files=all"), "Release requires a clean checkout; use --preview for local drafts")
        require(git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}") == commit, "Checkout must match the exact release tag")
    repository_url = manifest["repository"]
    require(re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository_url), "Expected a GitHub repository URL")
    repository = repository_url.removeprefix("https://github.com/")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(["bash", "scripts/check_versions.sh"], cwd=ROOT, check=True)
    subprocess.run(["bash", "scripts/package_plugin.sh", "--output-dir", str(output)], cwd=ROOT, check=True,
                   env={**os.environ, "SOURCE_DATE_EPOCH": git("show", "-s", "--format=%ct", "HEAD")})
    validate_archives(output)

    stem = f"{name}-plugin-{version}"
    catalog_commit = "<release-commit-sha>" if preview else commit
    entry = {key: manifest[key] for key in ("name", "version", "description", "author", "homepage", "repository", "license", "keywords")}
    entry["source"] = {"source": "github", "repo": repository, "sha": catalog_commit}
    entry["category"] = "development"
    catalog_files = []
    for target in ("claude", "github", "grok"):
        selected = dict(entry)
        if target == "grok":
            selected = json.loads((ROOT / ".grok-plugin/marketplace.json").read_text())["plugins"][0]
            selected["source"] = {"source": "url", "url": f"{repository_url}.git", "sha": catalog_commit}
        filename = f"{name}-{target}-marketplace-{version}.json"
        dump(output / filename, selected)
        catalog_files.append(filename)

    release_url = f"{repository_url}/releases/tag/{tag}"
    download = "." if preview else f"{repository_url}/releases/download/{tag}"
    guide_name = f"{name}-submission-{version}.md"
    metadata_name = f"{name}-release-{version}.json"
    checksum_name = f"{stem}-SHA256SUMS.txt"
    assets = [f"{stem}.zip", f"{stem}.tar.gz", *catalog_files, guide_name, metadata_name, checksum_name]
    interface = manifest["extensions"]["com.openai"]["interface"]
    warning = "**LOCAL PREVIEW: may include uncommitted files. Catalog SHAs are placeholders; do not submit these entries.**\n\n" if preview else ""
    identity = (f"Local preview for {tag}. Base commit: `{commit}` (not the packaged source)." if preview else
                f"Release: [{tag}]({release_url}). Source commit: [`{commit}`]({repository_url}/tree/{commit}).")
    runbook = "../../docs/publishing.md" if preview else f"{repository_url}/blob/{commit}/docs/publishing.md"
    guide = f"""<!-- spiceai-marketplace-release:start -->
## Marketplace distribution: {name} {version}

{warning}{identity}
Public skills: {len(skills)}. Private maintainer skills and eval tooling are excluded.

Download the [plugin ZIP]({download}/{stem}.zip), [tar.gz]({download}/{stem}.tar.gz),
and [SHA-256 checksums]({download}/{checksum_name}). The ZIP is the OpenAI upload.
The archives contain the same files, including the existing MIT license and all client manifests.
Local validation does not establish marketplace approval.

| Destination | Prepared input | Remaining publishing action |
| --- | --- | --- |
| Claude | Public repository `{repository_url}`; optional [pinned catalog entry]({download}/{catalog_files[0]}) | Submit the repository through the [Claude directory portal guide](https://claude.com/blog/build-plugins-for-claude); complete review and publish when approved |
| OpenAI | [ZIP]({download}/{stem}.zip), bundled logo and listing metadata | Upload to [Plugins](https://platform.openai.com/plugins), select Spice AI's verified identity, resolve scans, submit, and publish after approval |
| GitHub Copilot | [Pinned entry]({download}/{catalog_files[1]}) | Add or update `spiceai` in [github/copilot-plugins](https://github.com/github/copilot-plugins); submit a PR under its contributing guide |
| Grok | [Pinned entry]({download}/{catalog_files[2]}) | Add or update `spiceai` in [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace), regenerate its index, validate, and submit a PR |

### Catalog contributions

These JSON files are single plugin entries, not replacement marketplace files. In a checkout of
the destination repo, replace the existing `plugins[]` entry named `spiceai`, or append it once.
GitHub's catalog is `.github/plugin/marketplace.json`; update its `.claude-plugin/marketplace.json`
compatibility catalog too. Grok's catalog is `.grok-plugin/marketplace.json`.
For Grok, run the upstream `scripts/generate-plugin-index.py`, then
`scripts/validate-catalog.py` and `scripts/generate-plugin-index.py --check`; commit the generated
index with the catalog change. Follow each repository's current CONTRIBUTING.md and PR template.
For updates, change the existing entry's version and SHA instead of creating a duplicate listing.

Suggested PR title: `Update spiceai to {version}` (use `Add spiceai {version}` for the first listing).
The PR should link this release and commit, describe the {len(skills)} public skills, and report the
upstream validation results. Neither preparing these entries nor a GitHub release submits an external PR.

### Install from the Spice AI marketplace

```text
claude plugin marketplace add {repository}
claude plugin install {name}@spiceai
codex plugin marketplace add {repository}
codex plugin add {name}@spiceai
copilot plugin marketplace add {repository}
copilot plugin install {name}@spiceai
grok plugin marketplace add {repository}
grok plugin install {name} --trust
```

These commands use the repository marketplace, independently of curated-directory approval.
To test these release bytes, extract the ZIP and add that local directory as the marketplace.
The catalogs use local paths, so installs from an extracted release keep its source version.

### OpenAI review follow-up

Keep the package name `spiceai`. A draft created with an older name needs a new `spiceai` draft.
Re-run skill scans for the actual uploaded ZIP. If privacy-policy assessment is incomplete,
use the portal's additional-review path with `{interface['privacyPolicyURL']}`; do not mark it passed locally.
Policy attestations and approval status remain in the portal.

See the [publishing runbook]({runbook}) for the release workflow,
network and credential disclosures, and current official submission references.
<!-- spiceai-marketplace-release:end -->
"""
    (output / guide_name).write_text(guide)
    metadata = {
        "name": name, "version": version, "tag": tag, "commit": commit,
        "repository": repository, "preview": preview, "skills": skills,
        "assets": assets, "submission_guide": guide_name,
        "openai_interface": interface,
        "marketplace_status": "prepared; external review and publication required",
    }
    dump(output / metadata_name, metadata)
    (output / checksum_name).write_text("".join(
        f"{hashlib.sha256((output / filename).read_bytes()).hexdigest()}  {filename}\n"
        for filename in assets if filename != checksum_name
    ))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(guide)
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--preview", action="store_true", help="Allow uncommitted files; mark the handoff as unsuitable for submission")
    args = parser.parse_args()
    try:
        metadata = prepare(args.output_dir, args.tag, args.preview)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"version": metadata["version"], "preview": metadata["preview"], "assets": metadata["assets"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
