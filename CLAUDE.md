# CLAUDE.md

This repo is the **Spice.ai Marketplace** — Agent Skills / plugins for AI coding agents working with the [Spice.ai OSS](https://spiceai.org) runtime. Compatible harnesses include Claude Code, Cursor, Codex, Grok, OpenCode, Pi, and others that support the open skills/plugin format.

## Repository Structure

```
.claude-plugin/
  plugin.json           # Plugin metadata (required)
skills/
  {skill-name}/         # kebab-case directory name
    SKILL.md            # Skill definition (required)
    scripts/            # Executable scripts (optional)
    examples/           # Example files (optional)
README.md
```

## Creating a New Skill

- Directory name: `kebab-case` (e.g., `spice-query`)
- Place in `skills/` directory
- Must include `SKILL.md` with frontmatter (`name`, `description`) and usage docs
- Keep `SKILL.md` under 500 lines — put detailed reference material in separate files
- Scripts use `#!/bin/bash`, `set -e`, stderr for status, stdout for JSON output

## SKILL.md Format

```markdown
---
name: {skill-name}
description: {Concise description (may be multiple short sentences) of when to use this skill, with trigger phrases.}
---

# {Skill Title}

{Brief description}

## Version Compatibility

{Target release line, how to check the user's runtime version, removed/deprecated table — see below}

{Usage, examples, output format, troubleshooting}
```

## Version Awareness

Skills target the Spice runtime release line in `.claude-plugin/plugin.json` (plugin `2.3.1` → Spice
v2.3.x). Users run older and newer runtimes, so each Spice skill must let the agent match its advice to
the user's version:

- **`## Version Compatibility` section** after the intro: the target line (`Written for **Spice
  v2.3.x** (checked against v2.3.1)`), how to check the runtime version (`spice version`, `spiced --version`, image tag — not
  the Spicepod `version: v2` field or SQL `version()`), and an `Old | Change | Use instead` table of
  removed, renamed, or deprecated config users may still have.
- **Inline markers**: unmarked content applies to v2.0.0 and later. Mark later additions `(v2.2.0+)`
  and changes `**Removed in v2.0.0**`, `**Deprecated in v2.2.0**`, `**Breaking in v2.3.0**`, using the
  patch release where the change shipped.
- **Sources**: date changes from release notes (`https://spiceai.org/releases/v2.3.1`; v2.0.0 is
  `/releases/v2.0-stable`) and versioned docs (`https://spiceai.org/docs/v2.2/...`). Never cite
  `/docs/next/` — it tracks trunk, not a release.
- **On a new Spice release**: bump every plugin manifest, update each skill's `checked against`
  release (and the target line when the minor changes), add markers for new features, and move newly
  removed or deprecated config into the table. `make check-versions` verifies the manifests agree and
  each skill names the plugin's release line and exact version.
