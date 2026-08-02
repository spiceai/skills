---
name: spice-ai
description: Add AI and LLM capabilities to Spice — tools, NSQL (text-to-SQL), memory, model routing/workers, and evals. Use this skill whenever the user wants to enable LLM tools (SQL, search, memory, MCP, web search), set up text-to-SQL via /v1/nsql, add persistent conversational memory, configure model routing with workers (load balancing, fallback, weighted distribution), set up evals, or use the OpenAI-compatible chat API. This skill covers AI features and orchestration. For configuring individual model providers (OpenAI, Anthropic, etc.), see spice-models.
---

# Add AI Capabilities

Spice integrates AI as a first-class runtime capability. Connect to hosted LLM providers or serve models locally, with an OpenAI-compatible API, tool use, text-to-SQL, and model routing — all configured in YAML.

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

`GET /v1/nsql/context` returns exactly what `/v1/nsql` injects into the model — SQL dialect,
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
| `sample_distinct_columns` | Sample distinct column values | auto   |
| `random_sample`           | Random row sampling           | auto   |
| `top_n_sample`            | Top N rows by ordering        | auto   |
| `memory:load`             | Load stored memories          | memory |
| `memory:store`            | Store new memories            | memory |

### Enable Tools

```yaml
models:
  - from: openai:gpt-4o
    name: analyst
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
      tools: auto # all default tools
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
      tools: auto, memory
```

### Web Search

The Perplexity-backed `websearch` tool was **removed**. Web search now runs through OpenAI's
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

Invoke it via `POST /v1/responses` or `spice chat --responses`.

### MCP Server Integration

```yaml
tools:
  - name: external_tools
    from: mcp
    params:
      mcp_endpoint: http://localhost:3000/mcp
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

Workers coordinate traffic across multiple models for load balancing, fallback, and weighted routing. Workers are called with the same API as models.

### Round Robin

```yaml
workers:
  - name: balanced
    type: load_balance
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
    type: load_balance
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
    type: load_balance
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
      openai_temperature: 0.1
      openai_response_format: "{ 'type': 'json_object' }"
```

### Local Model (GGUF)

```yaml
models:
  - from: file:./models/llama-3.gguf
    name: local_llama
```

## Evals

Evaluate model performance:

```yaml
evals:
  - name: accuracy_test
    description: Verify model understands the data.
    dataset: test_data
    scorers:
      - Match
```

## Documentation

- [Model Providers](https://spiceai.org/docs/components/models)
- [LLM Tools](https://spiceai.org/docs/components/tools)
- [Workers](https://spiceai.org/docs/features/workers)
- [Memory](https://spiceai.org/docs/features/large-language-models/memory)
- [Parameter Overrides](https://spiceai.org/docs/features/large-language-models/parameter_overrides)
- [Evals](https://spiceai.org/docs/features/large-language-models/evals)
- [MCP Integration](https://spiceai.org/docs/components/tools/mcp)
- [Model Grades Report](https://spiceai.org/docs/reference/models)
