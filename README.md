# Spice.ai OSS Agent Skills

A collection of skills for AI coding agents working with the [Spice.ai OSS](https://spiceai.org) runtime. Skills are packaged instructions and scripts that extend agent capabilities.

Skills follow the [Agent Skills](https://agentskills.io/) format.

## Available Skills

### spice-install

Install the Spice CLI and runtime.

**Use when:** "install Spice", "set up Spice", "get started with Spice"

### spicepod-config

Create and configure Spicepod manifests (`spicepod.yaml`).

**Use when:** "create a spicepod", "configure spicepod.yaml", "set up a Spice app", "initialize Spice project"

### spice-data-connector

Connect Spice to data sources like PostgreSQL, MySQL, S3, Databricks, Snowflake, and more.

**Use when:** "add a dataset", "connect to a database", "load data from S3", "configure a data source"

### spice-cli

Use the Spice CLI to manage Spicepods and interact with the runtime.

**Use when:** "run Spice", "query data", "start the runtime", "use spice commands", "check spice status"

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