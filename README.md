# Spice.ai Plugin for Claude Code

A Claude Code plugin with skills for working with the [Spice.ai OSS](https://spiceai.org) runtime — data federation, acceleration, search, AI/LLM, and cloud management.

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

## Installation

Add the marketplace and install the plugin:

```
/plugin marketplace add spiceai/skills
/plugin install spiceai@spiceai-skills
```

Skills are then available as `/spiceai:spice-setup`, `/spiceai:spice-ai`, `/spiceai:spicepod-config`, etc.

### Project-level auto-discovery

To auto-suggest the plugin for all contributors, add this to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "spiceai-skills": {
      "source": {
        "source": "github",
        "repo": "spiceai/skills"
      }
    }
  },
  "enabledPlugins": {
    "spiceai@spiceai-skills": true
  }
}
```

## References

- [Spice.ai OSS GitHub](https://github.com/spiceai/spiceai)
- [Spice Documentation](https://docs.spiceai.org)
- [Spicepod Reference](https://docs.spiceai.org/reference/spicepod)
- [Cookbook](https://github.com/spiceai/cookbook)

## License

MIT
