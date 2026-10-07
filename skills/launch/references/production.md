# Running a launched project in production

The production profile's checklist, and the operating facts behind the runbook. Applies to Spice.ai
Cloud managed projects running Spice v2.3.x (checked against v2.3.2).

## Checklist before calling it production

| Area | Done when |
| --- | --- |
| Credentials | Source credentials are project secrets, or org secrets linked to the project; none in the spicepod or the repo. Automation uses an OAuth client (`SPICE_CLOUD_CLIENT_ID`/`SECRET`), not a person's token |
| Source access | Each source uses a dedicated read-only user; Postgres uses `pg_sslmode: verify-full`; network allowlists cover Spice Cloud |
| Freshness | Every accelerated dataset has a `refresh_check_interval` (or CDC) that matches what the user said "fresh" means |
| Capacity | The accelerated total fits well under half the memory limit; `spice cloud metrics` shows headroom after `verify` |
| Resilience | MCP agent workloads: 1 replica (MCP sessions break across replicas), sized with `--cpu`/`--memory` where the org has private compute. SQL/HTTP-only workloads: 2+ replicas within `limits.replicas`. `verify` passes either way |
| Safety | `runtime.query.timeout` set (e.g. `30s`); model `tools` limited to what the use case needs |
| Runtime version | `stable` channel; a pinned `image_tag` only on Enterprise and only from `spice cloud images` |
| Alerts | Production monitor set active, targets reach a person and a paging system, fire drill delivered |
| Change control | `spicepod.yaml` in version control; deploys go through `spice-launch.sh deploy` or CI |
| Hand-off | `RUNBOOK.md` and `AGENT-CONNECT.md` committed, with Scenario notes filled in |

## Deploys and rollbacks

- Spice Cloud deploys the project's **stored** spicepod. `spice-launch.sh deploy` (or
  `spice cloud project update --spicepod spicepod.yaml`) replaces it on every deploy; local edits
  are never synchronized on their own.
- A new instance must become ready before it takes traffic. One that never does (a missing secret, a
  dataset in Error, a model that fails to load) leaves the deployment `in_progress` with no
  terminal state, while the previous instance keeps serving. `spice cloud deploy --wait` times out
  in that case; `spice-launch.sh deploy` reads the new instance's logs and dataset status and stops
  with the cause within about a minute.
- Deploying again supersedes a stuck deployment, so the fix is always: correct the spicepod or
  secret, deploy, verify.
- **Rollback** = deploy the previous `spicepod.yaml` from version control. Monitors, secrets, API keys,
  and the endpoint are unaffected.
- `deploy` → `verify` is the gate. `verify` exits 1 on any failed check, so CI can use it.

## Secrets and keys

- Rotate a source credential: update the value where it lives (the environment or `.env.local`
  for `spice-launch.sh secrets DIR --set NAME`; the org secret in the portal), then deploy. The
  runtime reads secrets at startup only.
- Project API keys come in pairs for zero-downtime rotation:
  `spice cloud api-keys --project ORG/NAME --regenerate 2`, move clients to key 2, then
  `--regenerate 1`. Keys look like `<project-id>|<hex>`: the `|` breaks unquoted shell and `.env`
  lines, so quote them.
- Data-plane clients send `X-API-Key: <key>` or `Authorization: Bearer <key>`; both work for
  `/v1/sql`, `/v1/chat/completions`, and `/v1/mcp`. Management API tokens never go to clients or
  into project secrets.
- OpenAI SDK clients (Python and TypeScript) must send `Accept-Encoding: identity`: in October
  2026, non-streaming `/v1/chat/completions` returned `502 Bad Gateway` whenever the request asked
  for gzip, deflate, or zstd, which the SDKs do by default. Streaming, `/v1/sql`, `/v1/nsql`,
  `/v1/search`, and `/v1/mcp` were unaffected. `verify` checks for it; `AGENT-CONNECT.md` sets the
  header.

## Capacity

- Default managed instance: 4 GiB memory limit. Arrow acceleration holds data uncompressed, at
  several times its Parquet size, and a too-large acceleration has driven an instance to 90% memory
  and an unhealthy state during loading. Size accelerations first. Resizing
  (`spice cloud project update --project ORG/NAME --memory 8Gi`, `--cpu`) needs private compute
  (`preflight` → `private_compute: true`); without it the update is refused and the instance stays
  at its default size (2 vCPU / 4 GiB in testing).
- **One replica means a short gap on each deploy.** In testing, a 1-replica deploy answered 5xx
  for about 9 seconds while the instance switched (4 of 25 one-second probes). Deploy outside busy
  hours, or keep SQL/HTTP-only workloads on 2 replicas.
- **Availability requires observed signals.** Instance-health and dataset-status monitors are
  released for managed projects. An enabled monitor or quiet failure counter does not prove a
  healthy endpoint. Inspect telemetry and investigate unavailable prerequisites. Run an external
  canary every few minutes, for example a scheduler that runs `spice-launch.sh status DIR` or
  `curl -sf -H "X-API-Key: $SPICE_API_KEY" ENDPOINT/v1/ready` and alerts when it fails.
- **Replicas and MCP.** An MCP session (`Mcp-Session-Id`) lives in the memory of the instance that
  created it, and with more than one replica, requests in a session reach other instances: in
  testing, 31 of 75 tool calls across 15 sessions failed with `404 Session not found` on 2
  replicas, and 0 of 90 on 1. Until that changes, run MCP-serving projects on 1 replica and scale it
  vertically; SQL, chat, and search over HTTP are stateless and scale out fine. `verify` makes 8
  calls in one session and fails if any is lost.
- Plan limits (`GET /v1/limits`, shown by `preflight`) include max replicas, an HTTP request timeout
  (90 s on Enterprise in testing), and a SQL query timeout. Agents that ask for whole tables hit
  those limits; views and `LIMIT`-friendly descriptions keep queries small.
- Model calls are billed by the provider, including a health-check call at each runtime start.
  Federated queries against a warehouse are billed by the warehouse; acceleration absorbs repeated
  agent reads.

## Runtime version

- Projects on the `stable` channel run the latest stable Spice.ai Enterprise build of the runtime
  (`2.3.2-enterprise-models` in October 2026); `deploy` reports the tag. A fork inherits its
  source's channel, which is why `create --base` resets it to `stable`.
- To hold a version, Enterprise plans can pin `image_tag` with a tag from `spice cloud images`
  (`spice cloud project update --image <tag>`). Other plans get `403 image_tag_requires_enterprise`.
- Before adopting a feature newer than v2.3.2, check the [changelog](https://docs.spice.ai/changelog)
  for what the channel runs.

## Pause, resume, delete

- Pause a demo between sessions without losing configuration: `POST /v1/projects/{id}/pause` and
  `POST /v1/projects/{id}/resume` (Management API). Deployments are refused while it is paused.
- `spice-launch.sh teardown DIR --yes` deletes the `launch:` monitors and, only if the helper created
  it, the project. Deleting a project removes its endpoint, keys, secrets, and monitors for good.

## What to add to the runbook by hand

`handoff` writes the facts it can read from Spice Cloud. Add a **Scenario notes** section with:

- Stand-in or pending sources, and the exact swap (the `from:` line to change and the secret to set).
- Example agent questions that worked during verification, and ones that didn't.
- Known data caveats: UPPERCASE Snowflake columns, string-typed hive partitions, timezone of
  timestamps.
- Owners: who receives each alert, and who can change the spicepod.
- Anything the user still owns: linking an org secret, renewing a certificate, widening a network
  allowlist.
