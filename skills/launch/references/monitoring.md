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

Units are each template's own: a **per-second rate** for the failure templates, **milliseconds**
for latency, **percent of the instance limit** for memory and CPU (a `memory_working_set`
threshold above 1000 is read as bytes), and a **count** of refresh errors in the window. `window`
is the range evaluated (`1m`, `5m`, `15m`, `30m`, `1h`); memory, dataset status, and instance health
read the current value and ignore it. `sustainSecs` is how long the condition must hold before
firing.

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

## Known false alarms

- **After a redeploy, CPU and memory may fire for the replaced instance.** Observed in four test
  projects about 15–20 minutes after a deploy (or after removing a replica): `memory` and `CPU`
  fire with "Project instance <old instance> stopped reporting telemetry" (or no reading), then
  resolve on their own within about 5 minutes. Check that the instance named in the email is not the
  current one (`spice cloud status --project ORG/NAME`); if so, it is this, not an outage. No monitor
  setting suppresses it, so mention it in the runbook.
- **The email's severity label can differ from the monitor's.** A `critical` memory monitor's
  emails read `[warn]` in testing. Route by monitor name, not by the label in the subject.

## Template availability

Which templates an org can create varies with release and early access. `monitors` creates each
in turn, and a `404 monitor_template_unavailable` becomes `template_unavailable` in the output; it
is not an error. One code covers every reason (not released for the org, unmanaged project, no
CPU limit for `container_cpu`), and no route lists the available templates, so a create attempt
is the test. In October 2026 a managed project on an Enterprise org accepted `query_failures`,
`http_5xx`, `flight_failures`, `query_latency_p99`, `memory_working_set`, `container_cpu`, and
`llm_failures`, and refused `instance_health`, `dataset_refresh_errors`, `dataset_status`, and
`query_latency_p95`. The last is retired for new monitors: use `query_latency_p99`.

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

## Fire drill

`fire-drill` proves the path from metric to inbox:

1. It creates `launch: fire drill` (`query_failures > 0`, 1-minute window, no sustain, severity
   `warn`), sending to the same email and Slack targets as `launch: query failures`. HTTP targets
   are not copied, because their token cannot be read back.
2. It sends one failing query (`SELECT * FROM spice_launch_fire_drill_missing_table`) every
   ~25 s: about 0.04/s, under the regular query-failure monitor's default 0.05/s, so only the drill
   fires. With `--query-failure-rate 0` the regular monitor fires too (a second alert).
3. It polls the monitor until `last_fired_at` is set (two to three minutes in testing).
4. It deletes the drill monitor in all cases.

Ask the user before running it: it sends one real notification to everyone on the targets. Then
ask them to confirm it arrived. `fired: true` proves Spice Cloud sent it; only the recipient can
confirm delivery, and only by telling you: never search their mailbox, chat, or other accounts
for it, even when a connected tool could.

## Data reactions

Data reactions (`/v1/projects/{id}/reactions`) fire on matching data rather than metrics: for
example, a row in `orders` with `status = 'failed'`, or a slow or failed task in task history. They
require Drasi to be enabled for the project; otherwise creation returns `409 DRASI_NOT_ENABLED`.
`spice-launch.sh` doesn't create them. When a scenario needs data-driven alerts, describe the
reaction (`templateId` `dataset_row_match` with `spec.dataset`, `column`, `value`, or
`task_history_error`), then create it with the Management API once Drasi is on. The cloud skill has
the request shapes.

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
