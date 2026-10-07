# Project monitor operations

Management API contract checked on **October 6, 2026**. Cloud changes independently of the runtime.
Use the [live OpenAPI](https://api.spice.ai/openapi.json) for later API changes.
The table and defaults below describe that production baseline; see the October 7 Dev check below
before applying them to `dev-api.spice.ai`.

## Choose the signal

Monitors require a **managed project**. BYOC and Cloud Connect projects do not support these
runtime monitors. All current templates are released; org early access is no longer required.
Check the project's Spicepod and effective resource limits before creating a monitor.

| Template | Condition unit and scope | Prerequisite / caveat |
| --- | --- | --- |
| `instance_health` | Current instance failures, eviction, OOM, startup failures, and observed restarts | Fixed `op: GT`, `threshold: 0`, `sustainSecs: 0`; collector status pipeline, not runtime readiness |
| `memory_working_set` | Percent of each instance's positive memory limit | Thresholds 0–1000 mean percent; larger legacy thresholds mean bytes aggregated project-wide |
| `container_cpu` | Percent of each instance's finite CPU limit | CPU request and cluster capacity are not the denominator |
| `query_failures` | Project-wide failures/second over `window` | Includes caller SQL mistakes in the current implementation; not server-only failures |
| `http_5xx` | Project-wide 5xx responses/second over `window` | Cloud HTTP telemetry; excludes 4xx |
| `flight_failures` | Project-wide failed Flight SQL DoGet requests/second over `window` | Nonzero Flight statuses; not yet server-cause-only classification |
| `query_latency_p99` | Milliseconds; p99 across project histogram buckets | Use p99 for new monitors |
| `llm_failures` | Project-wide failed model calls/second over `window` | At least one model configured; not yet server-cause-only classification |
| `dataset_refresh_errors` | Recorded refresh-error count per dataset over `window` | Acceleration configured; includes counted retries, not failed-job count |
| `dataset_status` | Numeric load state per selected dataset | `EQ` with state 0–5; excludes built-in `runtime.*` datasets |
| `query_latency_p95` | Milliseconds; saved p95 condition | Existing monitors only; preserve their meaning unless the user approves conversion |

Evaluations run every 60 seconds. API spec defaults are `window: 5m`, `sustainSecs: 300`, and
`severity: critical`; these are not every portal template's defaults. Set the complete intended
condition explicitly. Allowed windows: `1m`, `5m`, `15m`, `30m`, `1h`. Sustain is 0–86400 seconds.
Memory and dataset status ignore `window`; instance health uses a fixed five-minute eviction
observation window. Severity is metadata (`warn`/`critical`), not a destination-routing rule.

CPU and percentage-memory calculations group by physical instance, then use the maximum for each
stable instance name across replacements. Legacy byte-memory conditions retain project-wide
aggregation. Preserve saved units and thresholds; request approval before converting bytes to
percent or p95 to p99.
CPU and percentage-memory monitors have a 10-minute missing-series warning, grouped by stable
instance name, at `warn` severity. It is separate from high usage and has no observed usage value.
Never receiving a first sample is not proof of coverage; verify current metrics independently.

### Dataset status

States: 0 Initializing, 1 Ready, 2 Disabled, 3 Error, 4 Refreshing, 5 Shutting down.
Use `EQ` with one state, not a numeric range comparison. Select one `dataset` or up to 20 `datasets`;
if both exist, a nonempty list wins. Dotted names are supported. Omit both to watch all user datasets.

```json
{
  "name": "Orders and customers in Error",
  "templateId": "dataset_status",
  "spec": {
    "op": "EQ", "threshold": 3, "datasets": ["sales.orders", "sales.customers"],
    "window": "5m", "sustainSecs": 300, "severity": "critical"
  },
  "targets": [{"type": "email", "emails": ["oncall@example.com"]}]
}
```

Refresh-error resolution means no recorded error in the current window, not proof of a successful
refresh. Query the dataset and inspect refresh status before declaring data fresh.

## Update existing alerts

1. List monitors and reactions; identify the user's alert by UUID, project, name, and template.
2. GET that ID. Preserve fields the user did not ask to change, including units and disabled state.
3. PATCH the same ID. Monitor updates need `monitors:write` and org admin; reaction updates need
   `reactions:write` and org membership. A write scope alone does not grant the role.
4. GET again. Verify each changed field and the complete destination set. Report the same ID.

Use `/v1/projects/{projectId}/monitors/{alertId}` or the equivalent `/reactions/{alertId}`.
PATCH supports `name`, nullable `description`, `status`, `templateId`, `spec`, `targets`, legacy
`target`, and `recipientUserIds`. Omit `spec` for a destination-only update. A supplied spec is a
replacement, not a field merge: copy the current spec and change the intended fields. Supply a
new spec when changing template. Preserve legacy conditions on settings-only edits.

Disable with `{"status":"disabled"}`; re-enable with `{"status":"active"}` only when requested.
Delete only when the user wants removal, using DELETE on that UUID. Delete/recreate is not the
normal edit path: it changes the ID and loses continuity with the saved alert's history.

## Notification destinations

Use `targets` for one to three destinations, at most one per type:

```json
{
  "targets": [
    {"type": "email", "emails": ["oncall@example.com"]},
    {"type": "slack", "channelId": "C0123ABCD"},
    {"type": "http", "url": "https://example.com/alerts", "method": "POST"}
  ]
}
```

- `targets` replaces the complete set and takes precedence over singular `target`. A `target`-only
  PATCH replaces all destinations with that one sink. Omit both to keep the set.
- Email supports up to 20 `emails` and up to 50 org-member `recipientUserIds`. A recipient-ID-only
  PATCH changes the email sink's member recipients while preserving other sinks.
  For only the supplied email addresses, set `recipientUserIds: []` explicitly and verify both lists.
- Manual API creation defaults to the credential's user, or the org owner for machine credentials.
  Portal forms can use org alert email defaults; later changes to org defaults do not retarget
  existing alerts. Specify recipients explicitly when the user names an on-call team.
- Slack needs an org connection and a channel ID, not a channel name. Firing messages are updated
  and recovery is posted in the alert's thread.
- HTTP requires public HTTPS (no localhost/private destinations or URL credentials). Methods:
  `POST` (default), `PUT`, `PATCH`. Optional `token` is a Bearer token: source it from the environment,
  build JSON without putting it in command arguments, and never print or commit it.
- GET returns redacted `targets` and a compatibility `target`, never HTTP tokens. Omitting a token
  while updating the same webhook URL preserves its saved token; a changed URL requires supplying
  the intended token again. To remove a saved token, remove the HTTP sink, then add it without a
  token, with the user's approval. Avoid replaying redacted GET JSON as credentials for a new alert.
- `spec.includeDetails` is off by default. Enable only after the user approves disclosure of query
  text or matching data. Data-reaction model messages may include data even with details off.

## Configuration, firing, and observation

Management GET exposes `status`, `last_fired_at`, `last_resolved_at`, and, for CPU without its limit,
`evaluation_unavailable_reason: cpu_limit_missing`. `status: active` means enabled, not healthy.
A newer fire than resolve (or a fire with no resolve) indicates an open episode; a timestamp alone
does not prove all instances or datasets are observed or that notification delivery succeeded.

An existing CPU monitor stays visible when its limit disappears. Restore a finite CPU limit,
deploy, and inspect current metrics. Changing its recipients does not repair the missing signal.
Missing data is not proof of recovery. Check runtime readiness, running instances, datasets, and
metric freshness alongside the monitor. Use an external readiness/SQL canary for availability.

Pause deactivates project monitor backends and suppresses project notifications. Resume restores
eligible enabled monitors. Saved `active` configuration is not evidence that a paused project is
evaluating. Creation while paused returns `409`. Project deletion tears down alerts; failed cleanup
may require retry or support. Verify the live state after pause/resume or any failed update.

The richer observation contract in enhancement #5634 (waiting/missing coverage on GET, Interrupted
and Instance ended history outcomes) is not fully implemented in the checked public API. Do not
invent `state`, `state_reason`, or observation fields. Portal detail exposes `last_error`; the
public Management API does not currently expose it. Escalate unexplained missing telemetry.

## Portal features versus public API

Use the project's **Monitors** page for these existing features. The portal routes use the signed-in
session, not a Management Bearer token. Ask the user to use the portal, or use browser automation
only when authorized; these are not extra `/v1` endpoints.

| Feature | Portal route suffix under `/api/orgs/{orgName}/apps/{projectName}/alerts` | Verification |
| --- | --- | --- |
| Eligible template catalog | `/catalog` | Inspect prerequisites before creating |
| Condition preview | `/preview` | Signal preview is not delivery proof or historical replay |
| Manual Auto setup | `/auto-setup` | Inspect created, skipped, and failed monitors and recipients |
| Episode history | `/{alertId}/events` | Inspect firing/resolution payloads and affected instances/datasets |
| Send test notification | `/{alertId}/test` | Checks saved destination delivery, not signal evaluation |
| Test HTTP destination | `/test-http` | Checks the proposed webhook, not a live monitor condition |

Test notifications do not update `last_fired_at` or record a real firing event. Get permission
before sending one and ask the recipient to confirm arrival. Never inspect their inbox or chat.
For end-to-end evaluation, use a controlled fire drill with consent, then confirm real recovery.
The launch helper's deliberate SQL failures test its current rate-based query-failure monitor;
they do not prove instance-health, refresh, memory, or CPU signals work.

## Errors and completion

| Result | Action |
| --- | --- |
| `404 monitor_template_unavailable` | Check managed kind, model/acceleration configuration, CPU limit, and retired p95; avoid repeated speculative POSTs |
| `403` on monitor PATCH | Use an org-admin credential with `monitors:write`; preserve the existing alert |
| `409` name conflict | Names are case-insensitively unique across monitors and reactions; select the existing ID or a different name |
| Shared 20-alert cap | Includes non-deleted monitors and reactions, even disabled ones; get approval before deleting |
| `409 monitor_changed` | GET again and reconcile the concurrent edit before retrying |
| `502` on PATCH | Saved configuration may be committed; GET and retry the same update, not a replacement alert |
| `502` on DELETE | Alert is hidden but cleanup failed; retry DELETE using the same ID |
| `422` Slack unavailable | Connect Slack in org settings or choose an approved alternative |
| Reaction `429` / `503` | Wait for update lock / restore Drasi readiness, then GET and retry |

Done means the intended ID has the requested configuration, enabled state, and destinations on GET.
Report evaluation limitations and untested destinations separately. A successful API call, preview,
or test send alone is not end-to-end monitoring verification.

## Enhancement rollout boundary

[Project alert enhancement #5634](https://github.com/spicehq/cloud/issues/5634) is the roadmap, not
proof every acceptance item shipped. Checked against Cloud trunk `0369a2f54` and the live public
OpenAPI on October 6, 2026:

- Merged: monitor PATCH [#5955](https://github.com/spicehq/cloud/pull/5955), percentage memory #5979,
  dataset corrections #6018, pause cleanup #6012, multiple sinks #5984, instance health #6020,
  and removal of template feature flags [#6066](https://github.com/spicehq/cloud/pull/6066).
- Pending: automatic eight monitors and `default_alerts` on project creation/fork
  [#6087](https://github.com/spicehq/cloud/pull/6087). Use manual setup and list actual monitors;
  do not promise automatic defaults or send that field until the deployed API supports it.
- Pending: failure-count units and classification gates
  [#6088](https://github.com/spicehq/cloud/pull/6088). The checked production request-failure thresholds were rates.
  Inspect saved units and the deployed contract before changing thresholds or running a drill
  after rollout. Never reinterpret a saved failures/second threshold as a failure count.

### Dev verification: October 7, 2026

On `https://dev-api.spice.ai`, a temporary p99 monitor passed create, GET, same-ID PATCH, disable,
re-enable, list, and delete. Omitted destinations were preserved; explicit empty member recipients
stayed empty. Cleanup returned DELETE 200, GET 404, and an unchanged set of existing monitor IDs.
This verified configuration CRUD, not firing, recovery, delivery, or destination-replacement PATCH.

Dev OpenAPI now describes HTTP 5xx thresholds as estimated response **counts over the selected
window**; saved rate-based conditions retain responses/second. Failure monitors default to zero
sustain, other monitors to 300 seconds; explicit sustain values are preserved. Check the target
environment's OpenAPI and saved spec before selecting units or defaults; Dev is not proof of a
production rollout. Dev PATCH OpenAPI omits `targets`, so replacement of multiple destinations
needs separate verification rather than inference from the creation schema.
