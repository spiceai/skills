# Monitoring and alerts

What `spice-launch.sh monitors` creates, what each alert means, and how to tune it. Monitors are
Spice.ai Cloud project monitors (Management API `/v1/projects/{id}/monitors`). They evaluate
runtime metrics every 60 seconds and notify by email, Slack, or webhook.

## The alert sets

All are named `launch: <signal>`, so re-running `monitors` finds and updates them, and leaves other
monitors alone.

| Alert | Template | Fires when | demo | poc | production |
| --- | --- | --- | --- | --- | --- |
| query failures | `query_failures` | failed queries > 0.05/s (3/min) over 5m, for 5 min | warn | warn | critical |
| HTTP 5xx | `http_5xx` | any 5xx over 5m, for 5 min | warn | critical | critical |
| model failures | `llm_failures` | any failed model call over 5m, for 5 min (only with models) | warn | critical | critical |
| memory | `memory_working_set` | memory > 85% of the instance limit, for 5 min | warn | critical | critical |
| query latency p99 | `query_latency_p99` | p99 > threshold over 15m, for 10 min | — | warn | warn |
| dataset refresh errors | `dataset_refresh_errors` | any refresh error in 15m (only with accelerations) | — | warn | critical |
| CPU | `container_cpu` | CPU > 90% of the limit over 15m, for 15 min | — | — | warn |
| Flight failures | `flight_failures` | any failed Arrow Flight request over 5m, for 5 min | — | — | warn |
| dataset errors | `dataset_status` | a dataset in Error (state 3), for 5 min | — | — | critical |
| instance health | `instance_health` | an instance failed health checks (crash, OOM kill, eviction) | — | — | critical |

Monitor descriptions (the meaning and first response) are written when a monitor is created;
re-running `monitors` updates the condition and targets but keeps edited descriptions.
Every created, updated, or unchanged monitor is read back to verify enabled state, condition,
destinations, and CPU-limit availability. Disabled monitors stay disabled unless the user approves
`--enable-disabled`. Any disabled or failed verification blocks success; zero usable monitors also
fails. Unavailable templates produce `monitoring_incomplete`, which is not a production-ready result.
Profile changes leave old monitors intact and list them under `outside_profile`; review them before
any approved DELETE. Existing alerts are updated through PATCH with their original IDs and history.

Units are each template's own: a **per-second rate** for the failure templates, **milliseconds**
for latency, **percent of the instance limit** for memory and CPU (a `memory_working_set`
threshold above 1000 is read as bytes), and a **count** of refresh errors in the window. `window`
is the range evaluated (`1m`, `5m`, `15m`, `30m`, `1h`); memory, dataset status, and instance health
read the current value and ignore it. `sustainSecs` is how long the condition must hold before
firing.
Dataset status uses `EQ` with state 0 Initializing, 1 Ready, 2 Disabled, 3 Error, 4 Refreshing,
or 5 Shutting down. Select `spec.dataset` or up to 20 `spec.datasets` (dotted names supported),
or omit both for all user datasets; built-in `runtime.*` datasets are excluded. The helper's
production alert watches any user dataset in Error. Instance health requires `GT 0` and zero sustain;
its `window` field does not change the fixed five-minute eviction observation window.

## Tuning

- **Query failures and agents.** Agents generate SQL, and some of it fails; a good agent reads the
  error and retries. A zero threshold would page on normal agent behavior, so the default fires
  only on a sustained rate. For an app or dashboard issuing fixed queries, every failure is a bug:
  `--query-failure-rate 0`. For heavy agent traffic, raise it after a week of real data.
- **Latency.** `verify` records a client-observed p99 over uncached runs of its probe query (the first
  `--sql`, else a `LIMIT 10` read of the first accelerated dataset) and the time of each `--sql`
  query. `monitors` sets the threshold to the larger of 5× the probe's p99 and 2× the slowest
  `--sql`, rounded up to 100 ms, with a 1,000 ms floor (5,000 ms if `verify` never ran). Pass the
  scenario's heaviest legitimate query as a `--sql`, or the alert will fire on normal analytics;
  `--latency-ms` overrides it.
- **Memory.** 85% sustained is the warning before an out-of-memory restart. A large acceleration
  loading at startup can push memory over 90%. Fix it in the spicepod (federate it or narrow it with
  `refresh_sql`), not by raising the threshold.
- **Severity** (`warn`, `critical`) is recorded on each event and carried into the notification, so
  routing (for example, critical to the paging webhook) happens on the receiving side.

## Observation and lifecycle

- `active` is enabled configuration, not proof of current observation. GET exposes fire/resolve
  timestamps and CPU `evaluation_unavailable_reason: cpu_limit_missing`. Check live metrics and
  readiness as well. The broader waiting/interruption contract in enhancement #5634 is not fully
  present in the checked public API; do not invent observation fields or assume no fire means healthy.
- CPU and percentage memory group by physical instance, then take the maximum by stable instance
  name across replacements. The old replaced-instance false-alarm problem was addressed in Cloud
  #5990. Inspect any new missing-signal warning instead of dismissing it as an expected false alarm.
- Missing-signal warnings can be `warn` even when the configured resource threshold is `critical`.
  CPU and percentage-memory monitors warn after a series is absent for 10 minutes, grouped by
  stable instance name. Read the reason and affected instance; distinguish lost observation from
  high usage. A never-seen signal still requires an independent coverage check.
- Pause deactivates monitors and suppresses project notifications; resume restores eligible enabled
  monitors. Creation while paused returns `409`. After resume, check telemetry and readiness before
  declaring coverage restored. Deletion cleans up backends; retry a failed DELETE on the same ID.
- Request-failure monitors currently use rates and can count caller mistakes. The proposed server-only
  failure-count changes in #6088 are not merged as of October 6, 2026. Recheck saved units and the
  deployed API before changing thresholds or using this SQL-error drill after that rollout.
  **Dev check, October 7:** `dev-api.spice.ai` OpenAPI describes HTTP failures as window counts
  (saved rate conditions retain rates) and failure-monitor default sustain as zero. The alert-set
  table above describes the helper's rate-based profile, not those new API defaults. Inspect the
  target environment and saved spec before using it; p99 CRUD passed on Dev, but failure conditions,
  firing, recovery, and delivery were not tested.

## Template availability

Cloud #6066 removed the project-alert feature flag and release list on October 5, 2026. All listed
templates are available on appropriately configured **managed projects**, except p95, which is
retired for new monitors. LLM failures need models; refresh errors need acceleration; CPU needs an
effective finite CPU limit. BYOC and Cloud Connect are outside this monitor scope.

`404 monitor_template_unavailable` becomes `template_unavailable` in helper output. Inspect those
prerequisites rather than requesting early access or repeating POST. The portal has a template
catalog and previews, using session-authenticated routes; there is no equivalent public `/v1`
catalog route. Historical pre-release refusal observations are no longer the availability contract.
Automatic eight-monitor setup and create/fork `default_alerts` are pending in #6087; list actual
monitors instead of assuming new projects already have defaults.
Live availability can still differ by org and environment: an October 2026 personal-org launch
refused `query_failures` and `llm_failures` but accepted `dataset_refresh_errors`. Report actual
refusals as coverage gaps rather than assuming release documentation guarantees creation.

## Notification targets

| Flag | Target | Notes |
| --- | --- | --- |
| `--email a@b.com` (repeatable) | `{"type": "email", "emails": [...]}` | Up to 20 addresses |
| `--slack C0123ABCD` | `{"type": "slack", "channelId": "C0123ABCD"}` | A channel ID, not a name; Slack must be connected to the org (else `422`) |
| `--webhook https://... [--webhook-token-env VAR]` | `{"type": "http", "url": ..., "token": ...}` | A public HTTPS URL; the token is write-only (never returned) |
| none | default | Emails the credential's user; a machine (OAuth client) credential has no user, so the org owner is emailed |

A monitor holds at most one target of each type (three in total). Passing targets on a re-run
replaces the set on every `launch:` monitor. `--email` with notification details is safe:
`includeDetails` stays off, so query text and rows never leave Spice Cloud in an alert.
Explicit `--email` clears member-recipient IDs; readback checks both email and member lists.
Without flags on a re-run, existing destinations are preserved (new alerts use the default email).
The API's `targets` array replaces the full set; singular `target` replaces it with one sink.
Readback redacts HTTP tokens. Updating the same webhook URL without a token preserves the saved
token; changing the URL requires supplying its intended credentials. Supply the token again when
creating a separate temporary drill monitor. Never print it or pass its value as a CLI argument.

## Fire drill

`fire-drill` tests metric evaluation and attempts notification delivery; recipient confirmation
completes the path to inbox, Slack, or webhook:

1. It creates `launch: fire drill` (`query_failures > 0`, 1-minute window, no sustain, severity
   `warn`), sending to the saved targets of an enabled `launch:` monitor (query failures first). For HTTP,
   pass `--webhook-token-env VAR`, or `--webhook-no-token` if the destination is unauthenticated.
   It stops before creating anything if webhook credentials are unconfirmed.
   If `query_failures` is unavailable, it uses `memory_working_set > 1%`, without failing queries.
2. For `query_failures`, it sends one failing query (`SELECT * FROM spice_launch_fire_drill_missing_table`) every
   ~25 s: about 0.04/s, under the regular query-failure monitor's default 0.05/s, so only the drill
   fires. With `--query-failure-rate 0` the regular monitor fires too (a second alert).
3. It polls the monitor until `last_fired_at` is set (two to three minutes in testing).
4. It stops failed queries and waits for a recorded recovery before deletion. A timeout reports
   that downstream test incidents may need manual closure.
   For the memory fallback, it raises only the temporary rule to 1000% after firing, then waits
   for resolution. This tests the notification lifecycle, not recovery from actual memory pressure;
   the rule update requires org admin.
5. It attempts deletion in all cases and fails if cleanup fails; retry DELETE on the reported ID.

Ask the user before running it: it sends real firing and recovery notifications to the targets. Then
ask them to confirm it arrived at every destination. `fired: true` proves a firing was recorded,
not successful delivery; output is `alert_fired` with `delivery_confirmed: false`. Only the recipient
can confirm arrival: never search their mailbox, chat, or other accounts
for it, even when a connected tool could.

The portal's **Send test notification** checks saved delivery credentials without deliberately
failing SQL, updating `last_fired_at`, or recording a real firing event. It does not verify signal
evaluation. The Monitors page also provides episode history, previews, and manual Auto setup.
Those portal routes require the signed-in session, not the helper's Management Bearer token.
The SQL drill does not verify every other template; inspect actual signal
coverage and document any untested path before the production handoff.

## Data reactions

Data reactions (`/v1/projects/{id}/reactions`) fire on matching data rather than metrics: for
example, a row in `orders` with `status = 'failed'`, or a slow or failed task in task history. They
require Drasi to be enabled for the project; otherwise creation returns `409 DRASI_NOT_ENABLED`.
`spice-launch.sh` doesn't create them. When a scenario needs data-driven alerts, describe the
reaction (`templateId` `dataset_row_match` with `spec.dataset`, `column`, `value`, or
`task_history_error`), then create it with the Management API once Drasi is on. The cloud skill has
the request shapes.
Both monitors and reactions support PATCH on their existing UUIDs. Monitor PATCH requires org admin
and `monitors:write`; reaction PATCH requires org membership and `reactions:write`. Send a complete
replacement spec if changing conditions, or omit it for a destination-only edit. GET afterwards.

## Reading the signals behind an alert

```bash
spice cloud status --project ORG/NAME                 # deployment, instances, unhealthy datasets
spice cloud metrics --project ORG/NAME --window 5m    # CPU, memory, disk, rows ingested per pod
spice cloud logs --project ORG/NAME --limit 200       # WARN/ERROR lines (the --level filter is unreliable; read the text)
spice-launch.sh status DIR                            # all of the above plus each alert's last_fired_at
```

Slow or failing statements are in the runtime's task history over `/v1/sql`:

```sql
SELECT task, input, execution_duration_ms, error_message
FROM runtime.task_history
WHERE start_time > now() - INTERVAL '1 hour'
ORDER BY execution_duration_ms DESC
LIMIT 20;
```
