---
name: launch
description: Launch a Spice.ai project end to end from a plain-language scenario. It designs the spicepod for the user's sources and models, deploys it to Spice.ai Cloud, and proves the deployment serves rows, model answers, and MCP tool calls. It then adds monitors and alerts, runs an alert fire drill, and hands off a runbook and agent connection snippets. Use it for demos, POCs, and greenfield production projects — "serve our Snowflake, Postgres, and S3 data to agents with OpenAI", "spin up a Spice demo on Cloud for tomorrow", "deploy this spicepod to Spice Cloud with alerting", "make our Spice POC production-ready" — and whenever a new Spice deployment must work and be operable, not just configured. Bundles scripts/spice-launch.sh. For a local-only first run use setup; for one-off Cloud API calls use cloud.
---

# Launch a Spice Project on Spice.ai Cloud

Turn a scenario — "agents need our Snowflake, Postgres, and S3 data, with OpenAI models" — into a
Spice.ai Cloud project that is designed, deployed, tested, monitored, and documented. The result
is something a team can demo, evaluate, or run in production, not a config file that merely
validates.

You do the design work (turning the scenario into a spicepod). The bundled helper,
`scripts/spice-launch.sh` in this skill's directory, does everything mechanical and checks its
own results. Call it by its full path. Progress goes to stderr; each command prints one JSON result
and exits 1 with `error`, `hints`, and `next` when something is wrong.

| Command | What it does |
| --- | --- |
| `preflight DIR [--project ORG/NAME]` | CLI and runtime versions, the Cloud credential and its role in the org, plan limits, regions, spicepod validity, and which secret references are available locally |
| `local DIR` | Optional: runs the spicepod on a local runtime with local secrets for up to two minutes, reports each component, then stops that PID. Skips when some secrets exist only in Cloud |
| `create DIR --project ORG/NAME [--region R] [--base ORG/BASE] [--profile P] [--replicas N]` | Creates a managed project (`--kind set`), or forks a base project to inherit its credentials, on the `stable` channel. Reuses an existing project |
| `secrets DIR [--set NAME]` | Stores each `${ secrets:NAME }` the spicepod uses as a project secret, reading values from the environment, `.env.local`, or `.env` |
| `deploy DIR [--timeout S]` | Uploads the spicepod, deploys, and watches the new instance. It stops early on an unresolved secret, a dataset stuck in Error, or a model that fails to load, then confirms the endpoint serves the new spicepod |
| `verify DIR [--sql Q]... [--ask Q --expect A] [--search T] [--nsql Q]` | Checks readiness, rows from every dataset and view, model answers (including a tool-grounded answer), embeddings, and an MCP session of several `sql` calls. Measures p50/p99 latency |
| `monitors DIR --profile P [--email E]... [--slack C] [--webhook URL] [--enable-disabled]` | Creates or updates the profile's alerts in place and reads them back. Preserves disabled state unless explicitly approved; reports incomplete coverage |
| `fire-drill DIR [--webhook-token-env VAR \| --webhook-no-token]` | Tests metric evaluation: a temporary monitor fires, records recovery, then is deleted. Sends real notifications; recipients must confirm delivery |
| `handoff DIR` | Writes `RUNBOOK.md` and `AGENT-CONNECT.md` from the live project; a re-run replaces only the text between its markers |
| `status DIR` | One-shot health: deployment, instances, unhealthy datasets, alerts and when they last fired, recent problems |
| `teardown DIR --yes` | Deletes the `launch:` monitors, and the project only if this helper created it |

State, without secrets, lives in `DIR/.spice-launch/state.json`. `create` adds `.env`, `.env.local`,
`.spice-launch/`, and `.spice/` to `DIR/.gitignore`.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.2) and the Spice.ai Cloud Management API as
tested in October 2026. What to check:

- **The local CLI**: `spice version` (also `spice version -o json`). The helper needs `spice cloud`
  subcommands from CLI v2.3.x (`project create --kind`, `deploy`, `status`, `logs`, `datasets
  --instance`). Older CLIs lack some of them, so read `spice cloud --help` before working around a
  missing command. Installation and upgrades are user-managed: link
  [the installation docs](https://spiceai.org/docs/installation), never run an installer.
- **The project's runtime**: Cloud resolves it from the project's channel (`stable` by default here).
  `deploy` reports the `image_tag` it ran, e.g. `2.3.2-enterprise-models`, and `spiced --version` is
  irrelevant to Cloud. Stable can trail the newest OSS release, so check the
  [changelog](https://docs.spice.ai/changelog) before relying on a feature newer than v2.3.2. Not the
  runtime version: `version: v2` in `spicepod.yaml` or SQL `version()`.
- **Markers**: unmarked content applies to v2.0.0 and later; later additions are marked `(vX.Y.Z+)`.
  On an older runtime, use that line's docs (`https://spiceai.org/docs/v2.2/...`; v2.3 is the
  current, unversioned `https://spiceai.org/docs/...`), never `/docs/next/`.

| Old | Change | Use instead |
| --- | --- | --- |
| `spice cloud project create NAME --region R` | Without `--kind` it creates a Cloud Connect project, which Spice does not run (and `--region` is rejected) | `--kind set --region R` (the helper does this) |
| Management API `/v1/apps` routes, `cname` | Deprecated in Aug 2026 (still served) | `/v1/projects`, `region` |
| MCP over SSE (`/v1/mcp/sse`) | Changed in v2.0.0 | Streamable HTTP at `/v1/mcp` |
| `query_latency_p95` monitor | Closed to new monitors | `query_latency_p99` |
| `memory_working_set` threshold in bytes | Now percent of the instance memory limit (values above 1000 still mean bytes) | A percentage such as `85` |
| `openai_tools` model param | Deprecated; attaches no tools | `tools` |
| `image_tag` on a non-Enterprise plan | Rejected (`403 image_tag_requires_enterprise`) | The project's channel |
| `google_api_key` | Breaking in v2.3.0 | Vertex AI params (`google_project`, `google_location`, a credential) |

## What "launched" means

`spice validate` passing, a project existing, or a deployment reading `succeeded` is not done. A
deployment whose new instance never becomes ready sits `in_progress` indefinitely while the
**previous version keeps serving**, so `/v1/ready` can say `ready` with the old datasets. Report
success only when all of these hold:

1. A managed project exists in the intended org and region on the intended channel.
2. The latest deployment succeeded, the runtime's startup check reports every secret reference
   resolved, and the endpoint serves every dataset and model of *this* spicepod as `Ready`.
   `deploy` checks all three (views are not listed by the runtime; `verify` queries them).
3. Every dataset and view returns rows over `/v1/sql`; each model answers, and a model with tools
   answers a data question with the right number; agents can call the MCP `sql` tool. `verify`
   checks these.
4. A latency baseline (p50/p99 over uncached queries) is recorded.
5. Monitors for the profile are enabled and read back with the user's notification targets. Signal
   coverage is checked separately; disabled or unavailable monitors are explicit gaps. With the
   user's consent, a fire drill fires and recipients confirm arrival at each destination.
6. `RUNBOOK.md` and `AGENT-CONNECT.md` exist, and the user has the final report (below).

## Workflow

### 1. Turn the scenario into a brief

Pull these from what the user said, and ask only for what you cannot default:

| Item | Default when unstated |
| --- | --- |
| Sources: type, location, tables or prefixes, rough size, freshness | None — ask for connection details. Never invent hosts, accounts, or table names |
| Where each credential lives | Ask: their environment/`.env.local`, project secrets, or org secrets linked to a base project |
| Consumers: agents over MCP, apps over SQL/HTTP, chat over the OpenAI API | Agents over MCP plus SQL |
| Models: provider and role (agent with tools, text-to-SQL, embeddings for search) | One chat model with `tools: auto` |
| Profile: `demo`, `poc`, or `production` | "Demo tomorrow" → demo; evaluation or customer trial → poc; "production", "greenfield", "operate", "on-call" → production |
| Org, project name, region | Org from `preflight`; a 4–38 character name such as `acme-agent-data`; the region nearest the data (`us-east-1` or `us-west-2`) |
| Alert recipients | The user's email |

When a named source has no credentials yet, say so and pick with the user:

- **demo**: a clearly labeled stand-in from public data playing the same role (see
  `references/scenarios.md`), swapped for the real source later.
- **poc / production**: deploy the rest and list the source as pending, or wait. Never mark it done.

Sources must be reachable from Spice Cloud. A database on `localhost`, a private subnet, or behind
a VPN cannot be read by a managed project, and neither can `file:` paths on the user's machine.
`deploy` refuses both before it starts.

### 2. Design the spicepod

Read `references/scenarios.md` for each source and model, then write `DIR/spicepod.yaml`. Start
from `examples/spicepod.agents.yaml` (Snowflake, Postgres, S3, and OpenAI for agents). The choices
that matter most:

- **Name and describe every dataset.** Agents discover data through `list_datasets` and
  `table_schema`, so `description:` is their only map.
- **Accelerate what is small and hot; federate what is large.** The default Cloud instance has a
  4 GiB memory limit. Arrow acceleration holds a table in memory at several times its Parquet size,
  and a table too large for it drove a test instance to 90% memory and an unhealthy state while
  loading. Accelerate tables you know are small, narrow big ones with `refresh_sql`, or leave them
  federated. When the size is unknown, deploy federated first and measure with `SELECT COUNT(*)`.
  More memory is only an option when `preflight` reports `private_compute: true`.
- **Write search `row_id`s as lists** (`row_id: [id]`): Spice Cloud rejects a single value when the
  deployment starts, although `spice validate` accepts it.
- **Secrets only as `${ secrets:NAME }`.** Never put a value in the spicepod.
- **Give models tools.** Without `tools`, chat answers can't query data; `tools: auto` grants `sql`,
  `table_schema`, `list_datasets`, `search`, and more. MCP clients get the tools regardless.
- **Add the Cloud runtime block.** Without `runtime.mcp.allowed_hosts: ["*"]`, `/v1/mcp` answers
  `403 Host header is not allowed` on Spice Cloud, and listing the public hostname does not help.
  The project API key still guards the endpoint. Add `runtime.query.timeout` so one runaway agent
  query can't hold the instance:

  ```yaml
  runtime:
    mcp:
      allowed_hosts: ["*"]
    query:
      timeout: 30s # (v2.2.0+)
  ```

- **Prefer views for cross-source questions** (`views:` with a SQL join of a Postgres and an S3
  dataset): agents then query one well-described table instead of rediscovering the join.

### 3. Preflight, and optionally run locally

```bash
spice-launch.sh preflight ./acme-agent-data --project acme/acme-agent-data
```

Stop on `blockers`. `management_token_missing` means no Management API credential was found. For
production, the user creates an OAuth client (organization **Settings → OAuth Clients**) with
apps, deployments, secrets, monitors, and reactions read/write scopes, and sets
`SPICE_CLOUD_CLIENT_ID` and `SPICE_CLOUD_CLIENT_SECRET`. `spice cloud login api` reads the same
variables. Also accepted: `SPICE_API_TOKEN` (a personal access token), or the credential
`spice cloud login` stored, read from the environment, `.env`, or the macOS keychain (macOS may
ask once to allow it).

`local` is worth running when the sources are reachable from this machine and the secrets are in
`.env.local`. It catches configuration mistakes in seconds, while each Cloud deploy cycle takes
minutes. It skips itself when some secrets exist only in Cloud, because components waiting on them
stall a local runtime instead of failing.

### 4. Create the project and store its secrets

```bash
spice-launch.sh create ./acme-agent-data --project acme/acme-agent-data --region us-east-1 --profile poc
spice-launch.sh secrets ./acme-agent-data
```

Where the credentials live decides the path:

- **The user has the values** (environment, `.env.local`): `secrets` pushes each referenced one as
  a project secret through the Management API. Values never appear in output or on a command line.
- **The org keeps them as org secrets** (organization **Settings → Secrets**): an org secret reaches
  a project's runtime only after it is linked to that project (project **Settings → Secrets** in the
  portal). The public API can't link one, but forking copies the links. If the org has a base
  project with the secrets linked, `create --base ORG/BASE` forks it and then resets the channel to
  `stable` (forks inherit the base's channel). Otherwise ask the user to link the secrets to the new
  project in the portal.

`secrets` lists anything it cannot confirm as `unverified`. The runtime's startup check during
`deploy` settles it.

### 5. Deploy

```bash
spice-launch.sh deploy ./acme-agent-data
```

On failure, read `error`, `unresolved`, `datasets`, `problems`, and `hints`, fix the cause, and run
`deploy` again (a new deployment supersedes the stuck one). Typical causes are in the
troubleshooting table. The `lint` notes flag configurations worth fixing: `pg_sslmode` weaker than
`verify-full` in production, S3 without `s3_auth`, accelerations that never refresh, and models
without tools.

### 6. Verify end to end

Prove what the scenario promised, not just that tables exist. Pass a cross-source query, an agent
question, and a search if the scenario has one:

```bash
spice-launch.sh verify ./acme-agent-data \
  --sql "SELECT c.segment, COUNT(*) AS orders FROM pg_orders o JOIN s3_customers c ON o.customer_id = c.id GROUP BY c.segment" \
  --ask "Which customer segment placed the most orders?" --expect "SMB"
```

Work out `--expect` from a `--sql` result first: without it, `--ask` only proves the model answered.
The first `--sql` is also the latency probe, so make it a representative agent query, and include
the scenario's heaviest legitimate query among the `--sql`s: `monitors` sets the latency alert above
it.

A failed check names its HTTP status and error. Fix it, deploy, and verify again. A `WARN` check
doesn't block, but it describes something clients must work around: put it in the report and in
the Scenario notes. The latency baseline is client-observed (it includes the network round trip
from this machine) over uncached queries; `monitors` derives its latency threshold from it.

### 7. Monitor and alert

```bash
spice-launch.sh monitors ./acme-agent-data --profile production --email oncall@acme.com --slack C0123ABCD
spice-launch.sh fire-drill ./acme-agent-data   # only after approval for firing and recovery notifications
```

`references/monitoring.md` lists each alert's meaning, units, thresholds, and first response.
Notes:

- Agents write SQL that sometimes fails and then retry, so query failures alert on a sustained rate
  (default 0.05/s for 5 minutes). For an app or dashboard where every failure matters, pass
  `--query-failure-rate 0`.
- Targets: email, a Slack channel ID (Slack must be connected to the org, else `422`), and an HTTPS
  webhook (`--webhook-token-env VAR` for its bearer token). Without targets, alerts email the
  credential's user, or the org owner for a machine credential.
- Templates are released for managed projects. `template_unavailable` means check project kind,
  configured models/acceleration, and effective CPU limit. Report the gap; repeated POSTs do not
  repair prerequisites. `monitoring_incomplete` is not production completion.
- Re-running `monitors` updates the `launch:` monitors' conditions and targets in place (keeping
  edited descriptions) and never touches others. Disabled monitors remain disabled and block
  completion; use `--enable-disabled` only after approval. Profile changes report old alerts as
  `outside_profile`; removal is a separate, approved action.
- Enabled is not healthy: inspect current metrics, readiness, dataset state, and missing-signal
  warnings. Replacement-instance false alarms were addressed upstream; treat a current missing
  signal as a coverage problem, not automatically as a harmless redeploy artifact.
- For a saved webhook, `fire-drill --webhook-token-env VAR` supplies its write-only token for the
  temporary alert. Use `--webhook-no-token` only for an unauthenticated destination. The portal's
  **Send test notification** uses saved credentials but tests delivery, not metric evaluation.
- Confirming delivery is the user's job: ask whether the alert arrived. Never search their mailbox,
  chat, or other accounts for it, even when a connected tool could.

### 8. Hand off

```bash
spice-launch.sh handoff ./acme-agent-data
```

Then fill in the **Scenario notes** section of `RUNBOOK.md`: stand-in or pending sources, agent
questions that work, data caveats, and anything the user still owns, such as linking a secret or
renewing a certificate. Write outside the `spice-launch` markers: a later `handoff` regenerates only
the text between them. Finish with this report, filled from the JSON:

```text
Launched acme/acme-agent-data (production) — https://spice.ai/acme/acme-agent-data
Endpoint https://us-east-1-prod-aws-data.spiceai.io — MCP at /v1/mcp, OpenAI-compatible at /v1
- Deployment 42370 succeeded in 18 s on 2.3.2-enterprise-models (stable); all 3 secrets resolved
- Verified 9/9: orders (Postgres, federated), customers (S3, 150,000 rows), assistant answered
  "how many customers" with 150000 via SQL, MCP sql tool returned rows
- Latency p50 283 ms, p99 303 ms (50 uncached queries, client-observed)
- Alerts: 9 active → oncall@acme.com and Slack C0123ABCD; fire drill delivered in 171 s
- Pending: Snowflake (no credentials yet); stand-in: none
- Client note: OpenAI SDK clients need Accept-Encoding: identity (set in AGENT-CONNECT.md)
- Files: spicepod.yaml, RUNBOOK.md, AGENT-CONNECT.md
- API key: spice cloud api-keys --project acme/acme-agent-data (keys contain `|`: quote them)
- Tear down: spice-launch.sh teardown ./acme-agent-data --yes
```

For a change later: edit `spicepod.yaml`, then `deploy` and `verify`; monitors persist across
deploys. For demos and POCs, offer `teardown` when the user is done, and run it only on their
confirmation.

## Profiles

| | demo | poc | production |
| --- | --- | --- | --- |
| Replicas | 1 | 1 | 1 when agents use MCP (sessions break across replicas); 2+ only for SQL/HTTP-only consumers, within `limits.replicas` |
| Stand-in data | Allowed, labeled | Only with agreement | No |
| Alerts | Query failures, 5xx, memory, model failures (warn) | + latency, refresh errors | + CPU, Flight, dataset and instance health; failures and memory are critical |
| Fire drill | Optional | Recommended | Required before calling it done (with the user's consent) |
| TLS to sources | `pg_sslmode: require` acceptable on a demo DB | `verify-full` preferred | `verify-full` |
| Teardown | Offer when done | Offer at the end of the evaluation | Never without an explicit request |

`references/production.md` has the production checklist: replicas, timeouts, key rotation,
rollbacks, channel and version pinning, and capacity.

## Don't

- **Report success from `deploy succeeded`, `/v1/ready`, or `spice validate` alone.** A stuck rollout
  keeps the old version answering; only `deploy` and `verify` compare against the new spicepod.
- **Put secret values in the spicepod, in output, or on a command line.** `spice cloud secrets set
  NAME VALUE` leaves the value in shell history; `secrets` reads it from the environment instead.
  Never copy Spice Cloud tokens or API keys into project secrets.
- **Point a Cloud dataset at `localhost`, a private IP, or `file:`.** Upload files to object
  storage; give databases a reachable endpoint with a read-only user.
- **Accelerate a table of unknown size in memory** on the default instance.
- **Run `fire-drill` without telling the user it sends a real alert,** or `teardown` without their
  confirmation. Never delete a project this helper did not create.
- **Read the user's mailbox, chat, or other accounts** to confirm an alert, or for anything else this
  workflow needs. Ask them.
- **Leave out `runtime.mcp.allowed_hosts: ["*"]`** when agents connect over MCP, or run more than
  one replica for MCP clients: requests in one MCP session then reach different instances and fail
  with `404 Session not found` (41% of calls in testing). Scale `--cpu` and `--memory` instead.
- **Install or upgrade Spice, or invent connection details.** Both are the user's to provide.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `deploy` stops with `unresolved` secrets, `not found in [env]` | The secret is neither a project secret nor an org secret linked to the project | `secrets` with the value in the environment, or link the org secret in the portal; deploy again |
| Postgres `error performing TLS handshake` | `pg_sslmode` defaults to `verify-full`, and the server certificate is self-signed, expired, or for another host | Check with `openssl s_client -starttls postgres -connect HOST:5432`; fix the cert or set `pg_sslrootcert`; `require` only for a demo DB |
| Postgres `Authentication failed` | Wrong user or password, or an empty secret | Fix the secret; deploy again |
| `Failed to load LLM ... Incorrect API key` or `You didn't provide an API key` | Bad or missing model key | Fix the secret. Until then the runtime never becomes ready |
| `Memory usage at 90% ... while loading` in `problems` | An acceleration larger than the instance | Federate it or narrow it with `refresh_sql`; raise `--memory` only with private compute |
| `deploy`: `could not start the deployment`, `400 Invalid spicepod configuration` | Cloud checks the published Spicepod schema, which is stricter than `spice validate` | Write search `row_id`s as lists; compare other fields with the [Spicepod reference](https://spiceai.org/docs/reference/spicepod) |
| `Resource limits can only be updated when private compute is enabled` | The org has no private compute | Keep the default size; federate or narrow accelerations |
| CPU or memory reports missing telemetry | Signal coverage lost for a stable instance name | Check running instances and telemetry; missing data is not recovery; see `references/monitoring.md` |
| `/v1/mcp` → `403 Host header is not allowed` | `runtime.mcp.allowed_hosts` missing | Add `["*"]` and deploy |
| MCP calls fail with `404 Session not found` mid-conversation; `verify` reports `session_not_found` | More than one replica: a session lives in one instance | `spice cloud project update --replicas 1` (scale CPU/memory instead), deploy |
| An OpenAI SDK client gets `502 Bad Gateway` from `/v1/chat/completions` while curl works; `verify` shows a WARN for `Accept-Encoding: gzip` | Non-streaming chat completions fail when the client asks for a compressed response, which the OpenAI SDKs do by default | Send `Accept-Encoding: identity` (Python `default_headers`, TypeScript `defaultHeaders`; AGENT-CONNECT.md does), or stream |
| `verify`: model answers but the data question is wrong | `tools` missing or too narrow, or a vague dataset description | `tools: auto`, better `description:` fields, a view |
| `monitors`: `create_failed` with 422 | Slack is not connected to the org | Connect Slack in org settings, or use email or a webhook |
| `monitors`: `update_failed` with 403 | Updating a monitor needs org admin | Use an admin's credential with `monitors:write`; retain the same alert ID |
| `monitors`: disabled / `verification_failed` / `monitoring_incomplete` | Disabled alert, mismatched saved fields, or missing prerequisites | Inspect GET and repair the reported gap; approve re-enabling separately |
| `fire-drill` never fires | No live deployment, or evaluation lag | Confirm `status` is healthy; retry with `--timeout 600` |
| `management_token_missing` | No credential the helper can read | Step 3 |
| `org_not_accessible` | An OAuth client from another org | OAuth clients act only in their own org; use that org's client |

## Documentation

- [Spice.ai Cloud](https://docs.spice.ai) and its [Management API](https://docs.spice.ai/api/management-api/management) ([OpenAPI](https://api.spice.ai/openapi.json))
- [Cloud CLI reference](https://spiceai.org/docs/cli/reference/cloud)
- [Spicepod reference](https://spiceai.org/docs/reference/spicepod) and [runtime settings](https://spiceai.org/docs/reference/spicepod/runtime)
- [Data connectors](https://spiceai.org/docs/components/data-connectors), [models](https://spiceai.org/docs/components/models), [MCP](https://spiceai.org/docs/features/large-language-models/mcp)
- Related skills: setup (local first run), cloud (individual Cloud API operations), terraform (infrastructure as code), connectors, models, chat, search, secrets
