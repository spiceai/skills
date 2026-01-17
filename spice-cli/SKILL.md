---
name: spice-cli
description: Use the Spice CLI to manage Spicepods and interact with the runtime. Use when asked to "run Spice", "query data", "start the runtime", "use spice commands", or "check spice status".
---

# Spice CLI

The Spice CLI manages Spicepods and interacts with the Spice runtime.

## Common Commands

| Command           | Description                                      |
|-------------------|--------------------------------------------------|
| `spice init`      | Initialize a new Spicepod in current directory   |
| `spice run`       | Start the Spice runtime                          |
| `spice sql`       | Start interactive SQL REPL                       |
| `spice chat`      | Start chat REPL (requires model configured)      |
| `spice add`       | Add a Spicepod dependency                        |
| `spice datasets`  | List loaded datasets                             |
| `spice models`    | List loaded models                               |
| `spice status`    | Show runtime status                              |
| `spice refresh`   | Refresh an accelerated dataset                   |
| `spice version`   | Show CLI and runtime version                     |
| `spice upgrade`   | Upgrade CLI to latest version                    |

## Quick Start

```bash
# Initialize new app
spice init my_app
cd my_app

# Add a sample dataset
spice add spiceai/quickstart

# Start the runtime
spice run

# In another terminal, query data
spice sql
> SELECT * FROM taxi_trips LIMIT 10;

# Or chat with AI (requires model in spicepod.yaml)
spice chat
> How many trips are in the dataset?
```

## Runtime Endpoints

When running `spice run`, these endpoints are available:

| Endpoint              | Default Address        |
|-----------------------|------------------------|
| HTTP API              | `http://127.0.0.1:8090`|
| Arrow Flight          | `127.0.0.1:50051`      |
| Metrics (Prometheus)  | `127.0.0.1:9090`       |
| OpenTelemetry         | `127.0.0.1:50052`      |

## Documentation References

Fetch these docs for detailed command usage and flags:

**CLI Overview:**
- [CLI Reference Index](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/index.md)
- [Command Reference](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/index.md)

**Core Commands:**
- [spice init](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/init.md)
- [spice run](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/run.md)
- [spice sql](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/sql.md)
- [spice chat](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/chat.md)
- [spice add](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/add.md)

**Dataset Commands:**
- [spice datasets](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/datasets.md)
- [spice dataset](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/dataset.md)
- [spice refresh](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/refresh.md)

**Other Commands:**
- [spice models](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/models.md)
- [spice status](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/status.md)
- [spice search](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/search.md)
- [spice catalogs](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/catalogs.md)
- [spice connect](https://github.com/spiceai/docs/raw/refs/heads/trunk/website/docs/cli/reference/connect.md)