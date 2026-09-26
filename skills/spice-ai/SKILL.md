---
name: spice-ai
description: Add AI and LLM capabilities to Spice — tools, NSQL (text-to-SQL), memory, model routing/workers, and the OpenAI-compatible chat API. Use this skill whenever the user wants to enable LLM tools (SQL, search, memory, MCP, web search), set up text-to-SQL via /v1/nsql, add persistent conversational memory, configure model routing with workers (load balancing, fallback, weighted distribution), or use the OpenAI-compatible chat API. This skill covers AI features and orchestration. For configuring individual model providers (OpenAI, Anthropic, etc.), see spice-models.
---

# Add AI Capabilities

Spice integrates AI as a first-class runtime capability. Connect to hosted LLM providers or serve models locally, with an OpenAI-compatible API, tool use, text-to-SQL, and model routing — all configured in YAML.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.2). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.2.

| Old | Change | Use instead |
| --- | --- | --- |
| `evals:` section, `/v1/evals` | Removed in v2.0.0 | Nothing — delete the section |
| `websearch` tool (Perplexity) | Removed in v2.0.0 | `responses_api: enabled` + `openai_responses_tools: web_search` |
| `spice chat --responses` | Removed in v2.0.0 | `POST /v1/responses` |
| MCP over SSE (`mcp:http://host/v1/mcp/sse`) | Changed in v2.0.0 (Streamable HTTP) | `mcp:http://host/v1/mcp` |
| `tools: auto` for the sampling tools | Changed in v2.0.0 | `tools: all` or `nsql`, or name the tools |
| `openai_<param>` on non-OpenAI providers | Deprecated in v1.5.0 | `<provider>_<param>` (e.g. `anthropic_temperature`) |
| `google_api_key` | Breaking in v2.3.0 | Vertex AI settings (see spice-models) |

## Configure a Model

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

| Provider               | From Format                              | Status            |
| ---------------------- | ---------------------------------------- | ----------------- |
| OpenAI (or compatible) | `openai:gpt-4o`                          | Stable            |
| Anthropic              | `anthropic:claude-sonnet-4-5`            | Alpha             |
| Azure OpenAI           | `azure:gpt-4o-mini`                      | Alpha             |
| Google (Vertex AI)     | `google:gemini-2.5-pro`                  | Alpha             |
| xAI                    | `xai:grok-4.3`                           | Alpha             |
| Amazon Bedrock         | `bedrock:amazon.nova-lite-v1:0`          | Alpha             |
| Databricks             | `databricks:databricks-llama-4-maverick` | Alpha             |
| Spice.ai (v2.2.0+)     | `spice.ai:openai/gpt-4o`                 | Release Candidate |
| HuggingFace            | `hf:meta-llama/Llama-3-8B-Instruct`      | Release Candidate |
| Local file             | `file:./models/llama.gguf`               | Release Candidate |

**Breaking in v2.3.0** — `from: google` authenticates against **Vertex AI**, not Google AI Studio:
set `google_project`, `google_location`, and a service-account credential (see spice-models).
`google_api_key` is no longer accepted.

## Using Models

### Chat API (OpenAI-compatible)

Existing applications using OpenAI SDKs can swap endpoints without code changes:

```bash
curl http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt4",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

### CLI

```bash
spice chat
chat> How many orders were placed last month?
```

### Text-to-SQL (NSQL)

The `/v1/nsql` endpoint converts natural language to SQL and executes it. Spice uses tools like `table_schema`, `random_sample`, and `sample_distinct_columns` to help models write accurate SQL:

```bash
curl -XPOST "http://localhost:8090/v1/nsql" \
  -H "Content-Type: application/json" \
  -d '{"query": "What was the highest tip any passenger gave?"}'
```

`GET /v1/nsql/context` (v2.1.0+) returns exactly what `/v1/nsql` injects into the model — SQL dialect,
per-dataset schemas (keys, indexes, searchable columns), the registered function inventory, and
optional sample rows. Use it to inspect or cache the context instead of guessing at it:

```bash
curl "http://localhost:8090/v1/nsql/context?include_examples=true&examples_limit=3"
```

`examples_limit` defaults to `3` (max `100`).

## Tools (Function Calling)

Tools extend LLM capabilities with runtime functions:

### Built-in Tools

| Tool                      | Description                   | Group  |
| ------------------------- | ----------------------------- | ------ |
| `list_datasets`           | List available datasets       | auto   |
| `sql`                     | Execute SQL queries           | auto   |
| `table_schema`            | Get table schema              | auto   |
| `search`                  | Vector similarity search      | auto   |
| `get_readiness`           | Component readiness states    | auto   |
| `get_current_datetime`    | Current UTC date and time     | auto   |
| `sample_distinct_columns` | Sample distinct column values | all    |
| `random_sample`           | Random row sampling           | all    |
| `top_n_sample`            | Top N rows by ordering        | all    |
| `memory:load`             | Load stored memories          | memory |
| `memory:store`            | Store new memories            | memory |

Groups: `auto` (default tools; uses `tool_search`/`tool_invoke` registry discovery when there are
more than 20 tools and an embedding model), `all` (`auto` + sampling tools, always direct),
`nsql` (SQL + sampling tools), `memory`, `search_registry`, `disabled`.

### Enable Tools

```yaml
models:
  - from: openai:gpt-4o
    name: analyst
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto # default tools; `all` adds the sampling tools
      # tools: sql, search      # or specific tools only
```

### Memory (Persistent Context)

```yaml
datasets:
  - from: memory:store
    name: llm_memory
    access: read_write

models:
  - from: openai:gpt-4o
    name: assistant
    params:
      tools: memory, sql
```

### Web Search

The Perplexity-backed `websearch` tool was **Removed in v2.0.0**. Web search runs through OpenAI's
hosted tool on the Responses API — `responses_api: enabled` is required:

```yaml
models:
  - from: openai:gpt-4o-mini # any model supported by the OpenAI Responses API
    name: researcher
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto
      responses_api: enabled # required for web search
      openai_responses_tools: web_search # allowlist the hosted tool
```

Invoke it via `POST /v1/responses` — hosted tools are not available from `/v1/chat/completions`.

### MCP Server Integration

The server address goes in `from` (`mcp:<url>` or `mcp:<command>`); a bare `from: mcp` is rejected.

```yaml
tools:
  - name: external_tools
    from: mcp:http://localhost:3000/mcp # Streamable HTTP
    params:
      mcp_auth_token: ${ secrets:MCP_TOKEN } # optional; or mcp_headers: 'X-API-Key: ...'
  - name: stdio_tools
    from: mcp:npx # stdio server run as a subprocess (or mcp:docker)
    params:
      mcp_args: -y <mcp-server-package>
```

### Tool Recursion Limit

```yaml
models:
  - from: openai:gpt-4o
    name: my_model
    params:
      tool_recursion_limit: 3 # default: 10
```

## Model Routing (Workers)

Workers coordinate traffic across multiple models for load balancing, fallback, and weighted routing. Workers are called with the same API as models. The `load_balance` block selects the behavior — a worker has no `type` field, and unknown fields fail Spicepod load.

### Round Robin

```yaml
workers:
  - name: balanced
    description: Distribute requests evenly.
    load_balance:
      routing:
        - from: model_a
        - from: model_b
```

### Fallback (Priority Order)

```yaml
workers:
  - name: fallback
    description: Try GPT-4o first, fall back to Claude.
    load_balance:
      routing:
        - from: gpt4
          order: 1
        - from: claude
          order: 2
```

### Weighted Distribution

```yaml
workers:
  - name: weighted
    description: Route 80% to fast model.
    load_balance:
      routing:
        - from: fast_model
          weight: 4 # 80%
        - from: slow_model
          weight: 1 # 20%
```

## Model Examples

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

### With System Prompt and Parameter Overrides

```yaml
models:
  - from: openai:gpt-4o
    name: pirate_haikus
    params:
      system_prompt: |
        Write everything in Haiku like a pirate.
      openai_temperature: 0.1 # prefix = provider prefix, e.g. anthropic_temperature, hf_temperature
      openai_response_format: { 'type': 'json_object' } # a YAML map, not a quoted string
```

### Local Model (GGUF)

```yaml
models:
  - from: file:./models/llama-3.gguf
    name: local_llama
```

## Documentation

- [Model Providers](https://spiceai.org/docs/components/models)
- [LLM Tools](https://spiceai.org/docs/components/tools)
- [Workers](https://spiceai.org/docs/features/workers)
- [Memory](https://spiceai.org/docs/features/large-language-models/memory)
- [Parameter Overrides](https://spiceai.org/docs/features/large-language-models/parameter_overrides)
- [MCP Integration](https://spiceai.org/docs/components/tools/mcp)
- [Model Grades Report](https://spiceai.org/docs/reference/models)
