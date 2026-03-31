# Spice.ai Plugin for Claude Code

A Claude Code plugin with skills for working with the [Spice.ai OSS](https://spiceai.org) runtime — data federation, acceleration, search, AI/LLM, and cloud management.

## Available Skills

| Skill | Description |
| --- | --- |
| [spice-setup](skills/spice-setup/) | Install Spice, initialize a project, and run the runtime |
| [spice-connect-data](skills/spice-connect-data/) | Connect to data sources and query across them with federated SQL |
| [spice-acceleration](skills/spice-acceleration/) | Accelerate data locally for sub-second query performance |
| [spice-search](skills/spice-search/) | Search with vector similarity, full-text keywords, or hybrid RRF |
| [spice-ai](skills/spice-ai/) | Add AI capabilities — chat, text-to-SQL, tools, memory, model routing |
| [spice-caching](skills/spice-caching/) | Cache query and search results with TTL and stale-while-revalidate |
| [spice-secrets](skills/spice-secrets/) | Manage credentials with secret stores |

## Installation

```
/install spiceai
```

Skills are available as `/spiceai:spice-setup`, `/spiceai:spice-ai`, `/spiceai:spicepod-config`, etc.

## References

- [Spice.ai OSS GitHub](https://github.com/spiceai/spiceai)
- [Spice Documentation](https://docs.spiceai.org)
- [Spicepod Reference](https://docs.spiceai.org/reference/spicepod)
- [Cookbook](https://github.com/spiceai/cookbook)

## License

MIT
