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
| `monitors DIR --profile P [--email E]... [--slack C] [--webhook URL]` | Creates or updates the profile's alert set in place. Templates the org can't use are reported, not fatal |
| `fire-drill DIR` | Proves alert delivery: a temporary monitor fires on deliberate failed queries (about 2–3 minutes), then is deleted. **Sends one real alert** |
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
5. Monitors for the profile are active with the user's notification targets, and, with the user's
   consent, a fire drill has delivered an alert.
6. `RUNBOOK.md` and `AGENT-CONNECT.md` exist, and the user has the final report (below).

## Workflow

### 1. Turn the scenario into a brief

Pull these from what the user said, and ask only for what you cannot default. Ask for everything
missing in **one** message, including the Cloud credential (step 3), since it is the first blocker
and takes the user a few minutes. Don't spread the questions over several turns.

| Item | Default when unstated |
| --- | --- |
| Sources: type, location, tables or prefixes, rough size, freshness | None — ask for connection details. Never invent hosts, accounts, or table names |
| Where each credential lives | Ask: their environment/`.env.local`, project secrets, or org secrets linked to a base project |
| Consumers: agents over MCP, apps over SQL/HTTP, chat over the OpenAI API | Agents over MCP plus SQL |
| Models: provider and role (agent with tools, text-to-SQL, embeddings for search) | One chat model with `tools: auto` |
| "Users bring their own LLM key" | Ask which they mean. **Hosted**: Spice loads one model per provider whose key the owner supplies, and clients pick one by `name`. **Client-side**: no models deployed; each user's own LLM client connects over MCP with its own key. Spice has no per-request key, so a key a user types in later reaches the runtime only as a project secret plus a deploy. Hosted is the default |
| Profile: `demo`, `poc`, or `production` | "Demo tomorrow" → demo; evaluation or customer trial → poc; "production", "greenfield", "operate", "on-call" → production |
| Org, project name, region | Org from `preflight`; a 4–38 character name such as `acme-agent-data`; the region nearest the data (`us-east-1` or `us-west-2`) |
| Alert recipients | The user's email |

When a named source has no credentials yet, say so and pick with the user:

- **demo**: a clearly labeled stand-in from public data playing the same role (see
  `references/scenarios.md`), swapped for the real source later.
- **poc / production**: deploy the rest and list the source as pending, or wait. Never mark it done.

When the user says to use stand-ins for everything, replace each source with a public dataset
(`references/scenarios.md` maps the common three-warehouse case), keep each real connector in a
comment beside it so the swap is one edit, and report every stand-in in the final report. A model
whose key isn't stored yet stays out of the spicepod (commented, with its secret name): a model
with a missing or bad key keeps the runtime from becoming ready, so one absent key would block the
whole deploy. Enable it with `secrets` and a redeploy once the key exists.

Sources must be reachable from Spice Cloud. A database on `localhost`, a private subnet, or behind
a VPN cannot be read by a managed project, and neither can `file:` paths on the user's machine.
`deploy` refuses both before it starts.

### 2. Design the spicepod

Read `references/scenarios.md` for each source and model, then write `DIR/spicepod.yaml`. Start
from `examples/spicepod.agents.yaml` (Snowflake, Postgres, S3, and OpenAI for agents), or
`examples/spicepod.unified-data.yaml` (Snowflake, Databricks, and Postgres as stand-ins, with a
three-source view and commented Claude, OpenAI, and Grok models). Put `DIR` outside any Git
checkout, such as `~/spice-projects/NAME`: it ends up holding `.env.local` with a Cloud token, and
`create` adds the `.gitignore` entries only after that file may already exist. The choices that
matter most:

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

A `spice cloud login` that reported success has still left `preflight` on `management_token_missing`
(the helper did not find the stored credential). The reliable fix is a personal access token: the user
creates one at <https://spice.ai/account/tokens>, runs `touch DIR/.env.local && chmod 600
DIR/.env.local`, opens that file in an editor (`open -e DIR/.env.local` on macOS), adds the line
`SPICE_API_TOKEN=<token>`, and saves. Don't ask them to paste the token into a command or into this
chat: a command puts it in shell history, and a silent `read -s` prompt took no input in an embedded
terminal. Never look for the credential yourself in the keychain, shell profile, or other files; the
helper reads the sources above, and a missing one is the user's to supply.

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
spice-launch.sh fire-drill ./acme-agent-data   # only after the user agrees to one real alert
```

`references/monitoring.md` lists each alert's meaning, units, thresholds, and first response.
Notes:

- Agents write SQL that sometimes fails and then retry, so query failures alert on a sustained rate
  (default 0.05/s for 5 minutes). For an app or dashboard where every failure matters, pass
  `--query-failure-rate 0`.
- Targets: email, a Slack channel ID (Slack must be connected to the org, else `422`), and an HTTPS
  webhook (`--webhook-token-env VAR` for its bearer token). Without targets, alerts email the
  credential's user, or the org owner for a machine credential.
- Some templates need early access (`template_unavailable` in the output). Report them as not
  available; don't retry.
- Re-running `monitors` updates the `launch:` monitors' conditions and targets in place (keeping
  edited descriptions) and never touches others.
- About 15–20 minutes after a redeploy, CPU and memory alerts can fire once for the replaced
  instance and resolve within minutes. `references/monitoring.md` shows how to recognize it.
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

**Sharing the project with a teammate.** Access belongs to the organization, not the project:
`POST /v1/members` (scope `members:write`; the `cloud` skill has the call) adds a person to the whole
org, so on a personal org they see everything in it. Tell the user that before adding anyone, and
offer a shared org instead when the project should stay separate. The call takes a Spice.ai
**username**, not an email, and the account must already exist (`404` otherwise): find it from a
repo, directory, or the person's public profile at `https://spice.ai/USERNAME`, check that the
profile describes them, and never guess. Confirm the username and the role (`member` by default,
`viewer` is read-only) with the user, then verify with `GET /v1/members`. Adding a member grants
access, so an environment may block the agent from doing it: give the user the portal path
(organization **Settings → Members**) or the exact command to run themselves.

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
- **Enable a model before its key is stored,** or add a person to the org by a guessed username.
  A missing model key blocks readiness for the whole deploy; a wrong username adds a stranger.
- **Hunt for a missing Cloud credential** in the keychain, shell profile, or other files. Ask the
  user to supply one (step 3).

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
| CPU and memory alerts fire about 15–20 minutes after a deploy, naming an old instance, then resolve | Telemetry from the replaced instance stops | Not an outage; see `references/monitoring.md` |
| `/v1/mcp` → `403 Host header is not allowed` | `runtime.mcp.allowed_hosts` missing | Add `["*"]` and deploy |
| MCP calls fail with `404 Session not found` mid-conversation; `verify` reports `session_not_found` | More than one replica: a session lives in one instance | `spice cloud project update --replicas 1` (scale CPU/memory instead), deploy |
| An OpenAI SDK client gets `502 Bad Gateway` from `/v1/chat/completions` while curl works; `verify` shows a WARN for `Accept-Encoding: gzip` | Non-streaming chat completions fail when the client asks for a compressed response, which the OpenAI SDKs do by default | Send `Accept-Encoding: identity` (Python `default_headers`, TypeScript `defaultHeaders`; AGENT-CONNECT.md does), or stream |
| `verify`: model answers but the data question is wrong | `tools` missing or too narrow, or a vague dataset description | `tools: auto`, better `description:` fields, a view |
| `monitors`: `create_failed` with 422 | Slack is not connected to the org | Connect Slack in org settings, or use email or a webhook |
| `monitors`: `update_failed` with 403 | Updating a monitor needs org admin | An admin's credential, or delete and recreate in the portal |
| `fire-drill` never fires | No live deployment, or evaluation lag | Confirm `status` is healthy; retry with `--timeout 600` |
| `management_token_missing` | No credential the helper can read | Step 3 |
| `org_not_accessible` | An OAuth client from another org | OAuth clients act only in their own org; use that org's client |

## Documentation

- [Spice.ai Cloud](https://docs.spice.ai) and its [Management API](https://docs.spice.ai/api/management-api/management) ([OpenAPI](https://api.spice.ai/openapi.json))
- [Cloud CLI reference](https://spiceai.org/docs/cli/reference/cloud)
- [Spicepod reference](https://spiceai.org/docs/reference/spicepod) and [runtime settings](https://spiceai.org/docs/reference/spicepod/runtime)
- [Data connectors](https://spiceai.org/docs/components/data-connectors), [models](https://spiceai.org/docs/components/models), [MCP](https://spiceai.org/docs/features/large-language-models/mcp)
- Related skills: setup (local first run), cloud (individual Cloud API operations), terraform (infrastructure as code), connectors, models, chat, search, secrets
