# CLAUDE.md

This repo is the `spiceai` Claude Code plugin — a collection of skills for AI agents working with the [Spice.ai OSS](https://spiceai.org) runtime.

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

{Brief description, usage, examples, output format, troubleshooting}
```
