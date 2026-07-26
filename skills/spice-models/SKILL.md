---
name: spice-models
description: Configure AI/LLM model providers and connections in Spice — OpenAI, Anthropic, Azure, Google, xAI, Bedrock, Databricks, HuggingFace, and local GGUF models. Use this skill whenever the user wants to add a model, configure a specific LLM provider, set up an OpenAI-compatible endpoint (e.g. Groq, Ollama), serve a local model, configure system prompts, set parameter overrides (temperature, response format), or understand which providers are available. This skill is the model connector reference. For AI features like tools, memory, workers, and NSQL, see spice-ai.
---

# Spice Model Providers

Model providers enable LLM chat completions and inference through a unified OpenAI-compatible API.

## Basic Configuration

```yaml
models:
  - from: <provider>:<model_id>
    name: <model_name>
    params:
      <provider>_api_key: ${ secrets:API_KEY }
      tools: auto # optional: enable runtime tools
      system_prompt: | # optional: default system prompt
        You are a helpful assistant.
```

## Supported Providers

| Provider               | From Format                         | Status            |
| ---------------------- | ----------------------------------- | ----------------- |
| OpenAI (or compatible) | `openai:gpt-4o`                     | Stable            |
| Anthropic              | `anthropic:claude-sonnet-4-5`       | Alpha             |
| Azure OpenAI           | `azure:my-deployment`               | Alpha             |
| Google AI              | `google:gemini-pro`                 | Alpha             |
| xAI                    | `xai:grok-4.3`                      | Alpha             |
| Amazon Bedrock         | `bedrock:anthropic.claude-3`        | Alpha             |
| Databricks             | `databricks:llama-3-70b`            | Alpha             |
| Spice.ai               | `spiceai:llama3`                    | Release Candidate |
| HuggingFace            | `hf:meta-llama/Llama-3-8B-Instruct` | Release Candidate |
| Local file             | `file:./models/llama.gguf`          | Release Candidate |

The `perplexity` provider was **removed** in v2.0.0 — re-point affected models at another
provider. For xAI, `from: xai` with no model defaults to `grok-4.3`.

## Features

| Feature                   | Description                            |
| ------------------------- | -------------------------------------- |
| **Tools**                 | SQL, search, memory, MCP               |
| **System Prompts**        | Declarative default system prompts     |
| **Parameterized Prompts** | Jinja templating in system prompts     |
| **Parameter Overrides**   | Temperature, response format, etc.     |
| **Memory**                | Persistent memory across conversations |
| **Evals**                 | Evaluate and track model performance   |
| **Local Serving**         | CUDA/Metal accelerated local models    |

## Examples

### OpenAI with Tools

```yaml
models:
  - from: openai:gpt-4o
    name: gpt4
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto
```

### OpenAI-Compatible Provider (e.g., Groq)

```yaml
models:
  - from: openai:llama3-groq-70b-8192-tool-use-preview
    name: groq-llama
    params:
      endpoint: https://api.groq.com/openai/v1
      openai_api_key: ${ secrets:GROQ_API_KEY }
```

### Model with Memory

```yaml
datasets:
  - from: memory:store
    name: llm_memory
    access: read_write

models:
  - from: openai:gpt-4o
    name: assistant
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: memory, sql
```

### With System Prompt and Parameter Overrides

```yaml
models:
  - from: openai:gpt-4o
    name: pirate_haikus
    params:
      system_prompt: |
        Write everything in Haiku like a pirate.
      openai_temperature: 0.1
      openai_response_format: "{ 'type': 'json_object' }"
```

### Local Model (GGUF)

```yaml
models:
  - from: file:./models/llama-3.gguf
    name: local_llama
```

## Using Models

### Chat Completions API (OpenAI-compatible)

```bash
curl http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt4",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

Existing applications using OpenAI SDKs can swap endpoints without code changes.

### NSQL (Text-to-SQL)

The `/v1/nsql` endpoint converts natural language to SQL and executes it. Spice uses tools like `table_schema`, `random_sample`, and `sample_distinct_columns` to help models write accurate, contextual SQL:

```bash
curl -XPOST "http://localhost:8090/v1/nsql" \
  -H "Content-Type: application/json" \
  -d '{"query": "What was the highest tip any passenger gave?"}'
```

### CLI

```bash
spice chat
chat> Hello!
```

## Documentation

- [Model Providers](https://spiceai.org/docs/components/models)
- [Models Reference](https://spiceai.org/docs/reference/spicepod/models)
- [Model Grades Report](https://spiceai.org/docs/reference/models)
- [LLM Tools](https://spiceai.org/docs/features/large-language-models/tools)
- [Memory](https://spiceai.org/docs/features/large-language-models/memory)
- [Parameter Overrides](https://spiceai.org/docs/features/large-language-models/parameter_overrides)
- [Parameterized Prompts](https://spiceai.org/docs/features/large-language-models/parameterized_prompts)
- [Evals](https://spiceai.org/docs/features/large-language-models/evals)
- [Local Model Serving](https://spiceai.org/docs/features/large-language-models/serving)
- [Web Search](https://spiceai.org/docs/features/web-search) — via OpenAI hosted tools; the `websearch` tool was removed
