---
name: spicepod-config
description: Create and configure Spicepod manifests (spicepod.yaml). Use when asked to "create a spicepod", "configure spicepod.yaml", "set up a Spice app", or "initialize Spice project".
---

# Spicepod Configuration

A Spicepod is a configuration package that defines datasets, models, embeddings, and secrets for a Spice application. Configuration is stored in `spicepod.yaml`.

## Basic Structure

```yaml
version: v1
kind: Spicepod
name: my_app

datasets:
  - from: <source>:<identifier>
    name: <dataset_name>

models:
  - from: <provider>:<model>
    name: <model_name>

secrets:
  - from: env
    name: env
```

## Key Sections

| Section       | Purpose                                           |
|---------------|---------------------------------------------------|
| `datasets`    | Data sources for federated SQL queries            |
| `models`      | AI/LLM models for chat and inference              |
| `embeddings`  | Embedding models for vector search                |
| `secrets`     | Secret stores for sensitive configuration         |
| `views`       | Virtual tables defined by SQL queries             |
| `dependencies`| Other Spicepods to include                        |

## CLI Commands

```bash
spice init my_app      # Create new spicepod.yaml
spice run              # Start runtime with current spicepod
spice add <spicepod>   # Add a dependency
```

## Documentation References

Fetch these docs for detailed configuration options:

**Spicepod Specification:**
- [Spicepod YAML Reference](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/reference/spicepod/index.md)
- [Datasets Reference](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/reference/spicepod/datasets.md)
- [Models Reference](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/reference/spicepod/models.md)
- [Embeddings Reference](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/reference/spicepod/embeddings.md)

**Getting Started:**
- [Spicepods Overview](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/getting-started/spicepods.md)
- [Getting Started Guide](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/getting-started/index.mdx)

**Secret Stores:**
- [Secret Stores Overview](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/components/secret-stores/index.md)