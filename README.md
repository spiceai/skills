# Spice.ai Marketplace

Open [Agent Skills](https://github.com/vercel-labs/skills) and plugins for AI coding agents working with the [Spice.ai OSS](https://spiceai.org) runtime — data federation, acceleration, search, AI/LLM, and cloud management.

This is the **Spice.ai Marketplace**: packaged skills/plugins any compatible harness can load. The format works across Claude Code, Cursor, Codex, Grok, OpenCode, Pi, and other agents that support the open Agent Skills / plugin standard — not Claude-only.

## Installation

### OpenAI Codex

```bash
npx skills add spiceai/skills -a codex
```

Global (all projects):

```bash
npx skills add spiceai/skills -g -a codex
```

Skills install under `.agents/skills/` (project) or `~/.codex/skills/` (global). Inside a Codex session you can also run `$skill-installer` and point it at `spiceai/skills`, then restart Codex if the skills do not appear. Verify with `/skills`.

See [Codex Skills](https://developers.openai.com/codex/skills).

**Publish (maintainers):** for the universal ChatGPT/Codex Plugins Directory, submit the repo (skills-only) via the [OpenAI plugin submission portal](https://developers.openai.com/plugins/deploy/submission). Compatibility manifest: [`.codex-plugin/plugin.json`](.codex-plugin/plugin.json); portable Agent Plugins: [`plugin.json`](plugin.json). Local/repo catalog: [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json) (`codex plugin marketplace add spiceai/skills`).


### Grok Build

```bash
npx skills add spiceai/skills -a grok
```

Or install as a Grok plugin from the repo:

```bash
grok plugin install spiceai/skills --trust
```

Add this repo as a marketplace source, then install `spiceai-skills`:

```bash
grok plugin marketplace add spiceai/skills
grok plugin install spiceai-skills --trust
```

Browse/install from the TUI with `/marketplace` or `/plugins`. Skills land in `.grok/skills/` (project) or `~/.grok/skills/` (global). Native manifests: [`.grok-plugin/plugin.json`](.grok-plugin/plugin.json) + [`.grok-plugin/marketplace.json`](.grok-plugin/marketplace.json). Grok also reads Claude Code marketplaces and `.agents/skills/` with no extra setup — see [Skills, Plugins & Marketplaces](https://docs.x.ai/build/features/skills-plugins-marketplaces).

**Publish (maintainers):** after merge, open a PR to [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace) adding a remote catalog entry for `spiceai-skills` pinned to a full commit `sha` of `spiceai/skills` (see their [CONTRIBUTING](https://github.com/xai-org/plugin-marketplace/blob/main/CONTRIBUTING.md)). Until that lands, users can still `grok plugin marketplace add spiceai/skills` or `grok plugin install spiceai/skills --trust`.

### Grok Bot

Grok Bot teammates use the same Agent Skills format. Install Spice skills into the Cursor skill paths the Bot shares:

```bash
npx skills add spiceai/skills -a cursor
```

Or ask a Grok Bot (or open **Settings → Plugins**) to add the `spiceai/skills` marketplace/plugin. After install, start a new Bot turn so the skills catalog refreshes.

### Cursor (plugin marketplace)

Install skills into Cursor paths:

```bash
npx skills add spiceai/skills -a cursor
```

Or add this repo as a Cursor plugin / Team Marketplace source (requires [`.cursor-plugin/plugin.json`](.cursor-plugin/plugin.json)).

**Publish (maintainers):** submit `https://github.com/spiceai/skills` at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish) after manifests land on `trunk`. Plugin id: `spiceai-skills` @ `2.3.0`.

### Other agents (`npx`)

```bash
npx skills add spiceai/skills
```

Target a specific harness with `-a` (examples: `opencode`, `pi`, `claude-code`, `cursor`). Use `-g` for a user-global install. Once installed, skills activate when the agent detects a relevant Spice task.

### Claude Code (plugin marketplace)

```text
/plugin marketplace add spiceai/skills
/plugin install skills@spiceai
```

Skills are then available as `/skills:spice-setup`, `/skills:spice-ai`, `/skills:spicepod-config`, etc.

#### Project-level auto-discovery (Claude Code)

To auto-suggest the plugin for all contributors, add this to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "spiceai": {
      "source": {
        "source": "github",
        "repo": "spiceai/skills"
      }
    }
  },
  "enabledPlugins": {
    "skills@spiceai": true
  }
}
```

## Versioning

Skills versions match the Spice.ai OSS runtime they target (e.g. `2.3.0` with runtime `v2.3.0`). Pin to GitHub release tag `v2.3.0` when you need a fixed surface, or use `trunk` for latest.

## Available Skills

| Skill | Description |
| --- | --- |
| [spice-setup](skills/spice-setup/) | Install Spice, initialize a project, and run the runtime |
| [spicepod-config](skills/spicepod-config/) | Create and configure spicepod.yaml manifests |
| [spice-connect-data](skills/spice-connect-data/) | Connect to data sources and query across them with federated SQL |
| [spice-data-connector](skills/spice-data-connector/) | Configure individual data source connectors (PostgreSQL, S3, Snowflake, etc.) |
| [spice-acceleration](skills/spice-acceleration/) | Accelerate data locally for sub-second query performance |
| [spice-accelerators](skills/spice-accelerators/) | Choose and configure acceleration engines (Arrow, DuckDB, SQLite, etc.) |
| [spice-search](skills/spice-search/) | Search with vector similarity, full-text keywords, or hybrid RRF |
| [spice-ai](skills/spice-ai/) | Add AI capabilities — tools, NSQL, memory, model routing, evals |
| [spice-models](skills/spice-models/) | Configure LLM providers (OpenAI, Anthropic, Azure, local GGUF, etc.) |
| [spice-text-to-sql](skills/spice-text-to-sql/) | Generate SQL for Spice's DataFusion engine and build text-to-SQL workflows |
| [spice-caching](skills/spice-caching/) | Cache query and search results with TTL and stale-while-revalidate |
| [spice-secrets](skills/spice-secrets/) | Manage credentials with secret stores |
| [spice-cloud-management](skills/spice-cloud-management/) | Manage Spice.ai Cloud resources via the Management API |
| [spice-terraform](skills/spice-terraform/) | Manage Spice.ai Cloud infrastructure as code with Terraform |

## Maintaining this repo

| Skill | Description |
| --- | --- |
| [improve-skills](skills/improve-skills/) | Weekly audit that keeps the skills above current with what has shipped |

`improve-skills` is for maintainers of this repo rather than for using Spice. It audits published Spice.ai releases for user-visible changes, routes each one to the skills it affects, applies the edits through `skill-creator`, runs the eval regression gate, and opens a PR. Every fact it publishes must be citable from a public source; see [its disclosure policy](skills/improve-skills/references/disclosure-policy.md).

## References

- [Spice.ai OSS GitHub](https://github.com/spiceai/spiceai)
- [Spice Documentation](https://docs.spiceai.org)
- [Spicepod Reference](https://docs.spiceai.org/reference/spicepod)
- [Cookbook](https://github.com/spiceai/cookbook)
- [Introducing Spice Skills](https://spice.ai/blog/introducing-spice-skills-for-ai-coding-agents)
- [Agent Skills CLI](https://github.com/vercel-labs/skills)

## License

MIT