# Spice.ai OSS Agent Skills

A collection of skills for AI coding agents working with the [Spice.ai OSS](https://spiceai.org) runtime. Skills are packaged instructions and scripts that extend agent capabilities.

Skills follow the [Agent Skills](https://agentskills.io/) format.

## Available Skills

| Skill | Description |
|---|---|
| [spice-setup](spice-setup/) | Install Spice, initialize a project, and run the runtime |
| [spice-connect-data](spice-connect-data/) | Connect to data sources and query across them with federated SQL |
| [spice-acceleration](spice-acceleration/) | Accelerate data locally for sub-second query performance |
| [spice-search](spice-search/) | Search with vector similarity, full-text keywords, or hybrid RRF |
| [spice-ai](spice-ai/) | Add AI capabilities — chat, text-to-SQL, tools, memory, model routing |
| [spice-caching](spice-caching/) | Cache query and search results with TTL and stale-while-revalidate |
| [spice-secrets](spice-secrets/) | Manage credentials with secret stores |

## Installation

```bash
npx skills add spiceai/skills
```

## Usage

Skills are automatically available once installed. The agent will use them when relevant tasks are detected.

## Skill Structure

Each skill contains:
- `SKILL.md` - Instructions for the agent
- `scripts/` - Helper scripts for automation (optional)
- `examples/` - Example configurations (optional)

## References

- [Spice.ai OSS GitHub](https://github.com/spiceai/spiceai)
- [Spice Documentation](https://docs.spiceai.org)
- [Spicepod Reference](https://docs.spiceai.org/reference/spicepod)
- [Cookbook](https://github.com/spiceai/cookbook)

## License

MIT