# Spice.ai OSS Agent Skills

A collection of skills for AI coding agents working with the [Spice.ai OSS](https://spiceai.org) runtime. Skills are packaged instructions and scripts that extend agent capabilities.

Skills follow the [Agent Skills](https://agentskills.io/) format.

## Available Skills

| Skill | Description | Triggers |
|-------|-------------|----------|
| [spice-install](spice-install/) | Install the Spice CLI and runtime | "install Spice", "set up Spice", "get started with Spice" |
| [spicepod-config](spicepod-config/) | Create and configure Spicepod manifests | "create a spicepod", "configure spicepod.yaml", "set up a Spice app" |
| [spice-cli](spice-cli/) | Use the Spice CLI to manage Spicepods | "run Spice", "query data", "start the runtime", "spice commands" |
| [spice-data-connector](spice-data-connector/) | Connect to PostgreSQL, MySQL, S3, Databricks, Snowflake, etc. | "add a dataset", "connect to a database", "load data from S3" |
| [spice-models](spice-models/) | Configure LLM providers (OpenAI, Anthropic, Azure, local) | "add a model", "configure LLM", "set up OpenAI" |
| [spice-embeddings](spice-embeddings/) | Configure embedding models for vector search | "add embeddings", "configure vector search", "set up semantic search" |
| [spice-accelerators](spice-accelerators/) | Configure data acceleration engines | "accelerate dataset", "enable caching", "configure DuckDB engine" |
| [spice-catalogs](spice-catalogs/) | Connect to Unity Catalog, Databricks, Iceberg catalogs | "add a catalog", "connect to Unity Catalog" |
| [spice-secrets](spice-secrets/) | Configure secret stores for credentials | "configure secrets", "add secret store", "use env secrets" |
| [spice-tools](spice-tools/) | Configure LLM tools for function calling | "add tools", "enable SQL tool", "configure MCP" |
| [spice-views](spice-views/) | Create SQL views as virtual tables | "create a view", "add SQL view" |
| [spice-vectors](spice-vectors/) | Configure vector search engines | "add vector engine", "configure S3 Vectors" |
| [spice-workers](spice-workers/) | Configure model load balancing and fallback | "add worker", "configure model routing" |

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