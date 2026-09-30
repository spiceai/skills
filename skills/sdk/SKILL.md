---
name: sdk
description: Integrate applications with Spice using the official Python, JavaScript/TypeScript, Go, Rust, Java, or .NET SDK. Use for client construction, local or Cloud endpoints, authentication, SQL and parameter binding, Arrow results, search, NSQL, streaming, timeouts, and SDK compatibility. Use cloud for project and infrastructure management, and sql for query authoring.
---

# Spice SDK Integration

Write application code against the user's chosen Spice SDK and installed dependency version.
Keep CLI, runtime HTTP, and SDK behavior consistent for the same operation. These clients target
the runtime data plane; project creation and deployments belong to the `cloud` skill.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.2). Check `spice version`, `spiced --version`,
or the deployed image tag for the runtime. SDK versions are independent: inspect the application's
dependency manifest and lockfile before choosing methods or options. The Spicepod `version: v2`
field and SQL `version()` do not identify either version.

The release references below establish the documented SDK surfaces; they are not a requirement
to upgrade an existing application. For another SDK release, read its matching tagged README
and source. Check runtime release notes before using a feature introduced after v2.0.0.

| Old assumption or configuration | Change | Use instead |
| --- | --- | --- |
| The SDK must have the runtime's version number | SDKs have independent release lines | Select methods from the installed SDK version |
| A Cloud Management API token authenticates runtime queries | Management and runtime use different credentials | Use the project's runtime API key; management tokens belong to `cloud` |
| An HTTP URL can be used as an Arrow Flight address | The transports have separate endpoints | Configure the HTTP and Flight endpoints for the same runtime or project |
| A method in the SDK default branch is available locally | It may be newer than the installed release | Use the matching published release and lockfile |

## Choose the existing language and client

| Language | Package and client surface | Release reference |
| --- | --- | --- |
| Python | `spicepy`, `Client`, `client.sql(...)` | [v4.0.0](https://github.com/spiceai/spicepy/blob/v4.0.0/README.md) |
| JavaScript / TypeScript | `@spiceai/spice`, `SpiceClient`, `client.sql(...)` | [v3.2.0](https://github.com/spiceai/spice.js/blob/v3.2.0/README.md) |
| Go | `github.com/spiceai/gospice/v9`, `SpiceClient`, `Sql(...)` | [v9.0.0](https://github.com/spiceai/gospice/blob/v9.0.0/README.md) |
| Rust | `spiceai`, `ClientBuilder`, `client.sql(...)` | [v4.0.0](https://github.com/spiceai/spice-rs/blob/v4.0.0/README.md) |
| Java | `ai.spice:spiceai`, `SpiceClient`, `client.sql(...)` | [v0.8.0](https://github.com/spiceai/spice-java/blob/v0.8.0/README.md) |
| .NET | `spiceai`, `SpiceClientBuilder`, `SqlAsync(...)` | [v0.4.0](https://github.com/spiceai/spice-dotnet/blob/v0.4.0/README.md) |

Prefer the language and dependency already present in the project. If they are unknown, inspect
the project before asking the user to choose. If a dependency is missing, prepare the manifest
change and link the relevant release documentation; dependency installation is a user-managed
prerequisite for this skill. Do not fetch and execute installers or repository bootstrap scripts.

## Establish the connection

1. Identify the existing runtime or Cloud project. Do not provision a runtime to test a client;
   use `setup` to check an existing local installation or `cloud` for requested project management.
2. Match HTTP and Flight endpoints to the same deployment. Local defaults are HTTP
   `http://127.0.0.1:8090` and Flight `grpc://127.0.0.1:50051`. For Cloud, use the project's documented
   endpoints and TLS, including its region; do not infer a Flight hostname from an HTTP hostname.
3. Read credentials from the application's environment or secret store. Do not hardcode or print
   keys. Preserve TLS verification; a certificate error needs the correct CA or endpoint.
4. Use the selected SDK release's constructor, timeouts, and cleanup API. Do not copy option names
   between languages: Python uses `http_url` / `flight_url`, while JavaScript uses `httpUrl` / `flightUrl`.
5. Validate with a small read-only query such as `SELECT 1` against the authorized target.

## Match the operation across interfaces

| User operation | CLI / runtime API | SDK guidance |
| --- | --- | --- |
| SQL | `spice sql`; `POST /v1/sql`; Arrow Flight | Use the client's SQL method and supported parameter binding; see `sql` |
| Search | `spice search`; `POST /v1/search` | Use the installed SDK's search method if available; preserve dataset and result options |
| Natural-language SQL | `POST /v1/nsql` | Use the installed SDK's NSQL method if available; requires a configured runtime model |
| Chat | `spice chat`; `POST /v1/chat/completions` | Use a documented chat method or an OpenAI-compatible client; see `chat` |
| Dataset refresh | `spice refresh <dataset>`; `POST /v1/datasets/{name}/acceleration/refresh` | Use a documented refresh method when available; this changes runtime state |
| Project / deployment management | `spice cloud`; Cloud Management API | Use `cloud`; do not invent these methods on a runtime SDK client |

SDK feature parity is not assumed. If a method is absent in the installed version, explain that
limit and use a documented runtime HTTP call when appropriate. Do not silently upgrade the client.
For Cloud NSQL, check the runtime minimum of **v2.1.0+** in the [Cloud API documentation](https://docs.spice.ai/api).

## SQL examples

These examples assume the listed SDK is already installed and a local runtime is already running.
They require no data source, API key, or external download.

Python (`spicepy` v4.0.0):

```python
from spicepy import Client

client = Client(
    flight_url="grpc://127.0.0.1:50051",
    http_url="http://127.0.0.1:8090",
)
table = client.sql("SELECT 1 AS ok").read_all()
print(table.to_pylist())
```

JavaScript (`@spiceai/spice` v3.2.0, local defaults):

```javascript
import { SpiceClient } from '@spiceai/spice';

const client = new SpiceClient();
const table = await client.sql('SELECT 1 AS ok');
console.table(table.toArray());
```

For user-supplied values, use the version's parameter API rather than string interpolation.
The parameter type and optional ADBC driver requirements differ across SDKs. Keep Arrow values
typed until an output format is requested; large integers, decimals, timestamps, and nulls can
lose information during JSON conversion. Stream large results and release readers, record
batches, and clients using the selected language's documented ownership rules.

## Validate and report

Check the project's existing type checker or compiler when available. Run integration queries
only against the authorized target with existing dependencies and credentials. Distinguish
compilation from a successful live query, and report any untested network or authentication path.
Do not retry writes, refreshes, or other mutations as if they were read-only queries.

## Documentation

- [Official SDK overview](https://spiceai.org/docs/sdks)
- [Runtime API reference](https://spiceai.org/docs/api)
- [Cloud runtime and Management APIs](https://docs.spice.ai/api)
- [Runtime releases](https://spiceai.org/releases)
