# Spice.ai Marketplace

Open [Agent Skills](https://github.com/vercel-labs/skills) and plugins for AI coding agents working with the [Spice.ai OSS](https://spiceai.org) runtime — data federation, acceleration, search, AI/LLM, and cloud management.

This is the **Spice.ai Marketplace**: packaged skills/plugins any compatible harness can load. The format works across Claude Code, Cursor, Codex, Grok, OpenCode, Pi, and other agents that support the open Agent Skills / plugin standard — not Claude-only.

## Installation

### OpenAI Codex

The plugin identifier is `spiceai`. When installed as a plugin, invoke its skills
as `$spiceai:setup`, `$spiceai:chat`, or `$spiceai:spicepod`.
For local plugin testing from this checkout:

```bash
codex plugin marketplace add .
codex plugin add spiceai@spiceai
```

The commands below install individual skills without a plugin namespace:

```bash
npx skills add spiceai/skills -a codex
```

Global (all projects):

```bash
npx skills add spiceai/skills -g -a codex
```

Skills install under `.agents/skills/` (project) or `~/.codex/skills/` (global). Inside a Codex session you can also run `$skill-installer` and point it at `spiceai/skills`, then restart Codex if the skills do not appear. Verify with `/skills`.

See [Codex Skills](https://developers.openai.com/codex/skills).

**Publish (maintainers):** build the skills-only upload package:

```bash
make check-versions
make package
```

In the [OpenAI Plugins dashboard](https://platform.openai.com/plugins), select the owning organization and project, choose **Upload new or existing plugin**, select the verified Spice AI developer identity, and upload `dist/spiceai-plugin-<version>.zip`. Resolve the metadata and skill scan findings, submit for review, and select **Publish plugin** after approval. Upload subsequent ZIPs to the existing listing using the same package name. If a draft was created under an older package name, create a new `spiceai` draft: OpenAI rejects package-name changes on an existing listing. See OpenAI's [submission guide](https://developers.openai.com/plugins/deploy/submission) for publishing permissions and verification requirements.

Listing metadata and bundled icons come from [`plugin.json`](plugin.json) and [`assets/`](assets/), with matching metadata in the [Codex compatibility manifest](.codex-plugin/plugin.json). The [local/repo catalog](.agents/plugins/marketplace.json) (`codex plugin marketplace add spiceai/skills`) supports local testing and distribution; adding it does not publish to the public directory. GitHub releases attach both archives, checksums, and marketplace submission materials using the same packaging script. See the [publishing runbook](https://github.com/spiceai/skills/blob/trunk/docs/publishing.md).

### GitHub Copilot

```bash
copilot plugin marketplace add spiceai/skills
copilot plugin install spiceai@spiceai
```

Copilot uses [`.github/plugin/marketplace.json`](.github/plugin/marketplace.json) and the portable
root [`plugin.json`](plugin.json). For a curated listing, contribute the release's generated catalog
entry to [github/copilot-plugins](https://github.com/github/copilot-plugins), following its contribution guide.


### Grok Build

```bash
npx skills add spiceai/skills -a grok
```

Or install as a Grok plugin from the repo:

```bash
grok plugin install spiceai/skills --trust
```

Add this repo as a marketplace source, then install `spiceai`:

```bash
grok plugin marketplace add spiceai/skills
grok plugin install spiceai --trust
```

Browse/install from the TUI with `/marketplace` or `/plugins`. Skills land in `.grok/skills/` (project) or `~/.grok/skills/` (global). Native manifests: [`.grok-plugin/plugin.json`](.grok-plugin/plugin.json) + [`.grok-plugin/marketplace.json`](.grok-plugin/marketplace.json). Grok also reads Claude Code marketplaces and `.agents/skills/` with no extra setup — see [Skills, Plugins & Marketplaces](https://docs.x.ai/build/features/skills-plugins-marketplaces).

**Publish (maintainers):** after merge, open a PR to [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace) adding a remote catalog entry for `spiceai` pinned to a full commit `sha` of `spiceai/skills` (see their [CONTRIBUTING](https://github.com/xai-org/plugin-marketplace/blob/main/CONTRIBUTING.md)). Until that lands, users can still `grok plugin marketplace add spiceai/skills` or `grok plugin install spiceai/skills --trust`.

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

**Publish (maintainers):** submit `https://github.com/spiceai/skills` at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish) after manifests land on `trunk`. Plugin id: `spiceai` @ `2.3.2`.

### Other agents (`npx`)

```bash
npx skills add spiceai/skills
```

Target a specific harness with `-a` (examples: `opencode`, `pi`, `claude-code`, `cursor`). Use `-g` for a user-global install. Once installed, skills activate when the agent detects a relevant Spice task.

### Claude Code (plugin marketplace)

```text
/plugin marketplace add spiceai/skills
/plugin install spiceai@spiceai
```

Skills are then available as `/spiceai:setup`, `/spiceai:chat`, `/spiceai:spicepod`, etc.

For the public Claude directory, submit this GitHub repository through the
[directory submission portal](https://claude.com/blog/build-plugins-for-claude), then complete
review and publication. Registering the repository marketplace is independent of directory approval.

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
    "spiceai@spiceai": true
  }
}
```

## Versioning

Pull requests validate metadata, private-skill exclusion, and packaging, and produce a submission
preview. Pushing a `v<version>` tag creates a draft GitHub release containing ZIP/tar archives,
checksums, full-SHA catalog entries for Claude/Copilot/Grok, and an OpenAI upload guide. Publishing
a GitHub release or manually rerunning the release workflow refreshes those assets and the generated
release-note section while preserving authored notes. Claude/OpenAI portal review and GitHub/Grok
catalog PRs remain separate publishing steps. See the [publishing runbook](https://github.com/spiceai/skills/blob/trunk/docs/publishing.md).

Skills versions match the Spice.ai OSS runtime they target (e.g. `2.3.2` with runtime `v2.3.2`). Pin to GitHub release tag `v2.3.2` when you need a fixed surface, or use `trunk` for latest.

The skills are version-aware. Each one names the release line it is written for, tells the agent to check your runtime version (`spice version`) before it recommends configuration, marks features added after v2.0.0 with the release that shipped them (for example `(v2.2.0+)`), and lists removed or deprecated configuration with its replacement. On an older runtime, the agent can then avoid newer settings and use the docs for your release (`https://spiceai.org/docs/v2.2/...`).

## Available Skills

| Skill | Description |
| --- | --- |
| [setup](skills/setup/) | Check an existing Spice installation, initialize a project, and run the runtime |
| [cookbook](skills/cookbook/) | Find, set up, and run recipes from the Spice.ai cookbook, including from a pull request |
| [spicepod](skills/spicepod/) | Create and configure spicepod.yaml manifests |
| [datasets](skills/datasets/) | Connect to data sources and query across them with federated SQL |
| [connectors](skills/connectors/) | Configure individual data source connectors (PostgreSQL, S3, Snowflake, etc.) |
| [acceleration](skills/acceleration/) | Accelerate data locally for sub-second query performance |
| [accelerators](skills/accelerators/) | Choose and configure acceleration engines (Arrow, DuckDB, SQLite, etc.) |
| [search](skills/search/) | Search with vector similarity, full-text keywords, or hybrid RRF |
| [chat](skills/chat/) | Chat through the CLI or API, with tools, memory, and model routing |
| [models](skills/models/) | Configure LLM providers (OpenAI, Anthropic, Azure, local GGUF, etc.) |
| [sql](skills/sql/) | Author and run SQL through the CLI, runtime API, or SDK; build text-to-SQL workflows |
| [cache](skills/cache/) | Cache query and search results with TTL and stale-while-revalidate |
| [secrets](skills/secrets/) | Manage credentials with secret stores |
| [cloud](skills/cloud/) | Manage Spice.ai Cloud resources via the Management API |
| [terraform](skills/terraform/) | Manage Spice.ai Cloud infrastructure as code with Terraform |
| [sdk](skills/sdk/) | Integrate Python, JavaScript/TypeScript, Go, Rust, Java, and .NET applications |

The skill names follow the CLI and API concepts where they overlap. A skill can cover several
related commands; configuration topics are not invented CLI subcommands.

| Skill | CLI, API, or SDK surface |
| --- | --- |
| `setup` | Existing installation, `spice init`, `spice run`, `spice version` |
| `sql` | `spice sql`, `/v1/sql`, `/v1/nsql`, SDK SQL methods |
| `search` | `spice search`, `/v1/search`, SDK search methods |
| `chat` / `models` | `spice chat`, `spice models`, OpenAI-compatible APIs and provider configuration |
| `datasets` / `connectors` | Dataset and catalog configuration, `spice datasets`, `/v1/datasets` |
| `cloud` | Available `spice cloud` commands and the Cloud Management API |
| `sdk` | Client construction, endpoints, credentials, typed results, and language-specific methods |
| `spicepod`, `acceleration`, `accelerators`, `cache`, `secrets` | Runtime configuration and related operations |
| `terraform` / `cookbook` | Infrastructure as code and documented recipe workflows |

Cloud runtime calls use project endpoints and project API keys. Cloud management operations
use the Management API and its access tokens. SDK versions are checked independently of the
runtime version. Installing individual skills without the plugin uses their short names,
such as `$sql`; plugin installs use `$spiceai:sql` or `/spiceai:sql` in the corresponding agent.

## References

- [Spice.ai OSS GitHub](https://github.com/spiceai/spiceai)
- [Spice Documentation](https://docs.spiceai.org)
- [Spicepod Reference](https://docs.spiceai.org/reference/spicepod)
- [Cookbook](https://github.com/spiceai/cookbook)
- [Introducing Spice Skills](https://spice.ai/blog/introducing-spice-skills-for-ai-coding-agents)
- [Agent Skills CLI](https://github.com/vercel-labs/skills)

## License

MIT
