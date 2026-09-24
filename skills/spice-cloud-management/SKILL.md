---
name: spice-cloud-management
description: Manage Spice.ai Cloud resources via the Management API — projects (formerly apps), project forks, deployments, secrets, API keys, and org members. Use this skill whenever the user wants to create, fork, or manage a Spice.ai Cloud project or app, copy or move a project to another region or cluster, trigger a deployment, manage cloud secrets or API keys, list regions or runtime versions, add/remove org members, or automate any Spice.ai Cloud operation. Also use when the user mentions "spice.ai cloud", "deploy to spice", "fork a project", "cloud API", or wants to use the Spice.ai hosted platform. For infrastructure-as-code with Terraform, see spice-terraform.
---

# Spice.ai Cloud Management

Manage Spice.ai Cloud resources through the Management API (control plane) at `https://api.spice.ai`. Create and fork projects, trigger deployments, manage secrets and API keys, and administer organization members.

**Renamed in Aug 2026:** apps are now **projects**. The `/v1/projects` routes are canonical; every `/v1/apps` route is still served as a legacy alias (marked deprecated in the OpenAPI spec). Only the list envelope differs — `GET /v1/projects` returns `{"projects": [...]}`, `GET /v1/apps` returns `{"apps": [...]}`. Scope names stay `apps:*`.

## Version Compatibility

Written against the Spice.ai Cloud Management API as documented in September 2026, for projects running **Spice v2.3.x** (checked against v2.3.1). Two versions matter:

- **The project's runtime**: each deployment resolves the runtime from the project's `update_channel` (`stable`, `preview`, `nightly`) and `version` range unless `image_tag` pins it. Stable can trail the latest OSS release, so check `GET /v1/projects/{projectId}` and the [changelog](https://docs.spice.ai/changelog) before recommending a runtime feature. Cloud APIs have runtime minimums — the MCP API needs v2.0.0+ and `/v1/nsql` needs v2.1.0+.
- **The API surface**: Cloud API changes are dated by the changelog month, not by a runtime release.

| Old | Change | Use instead |
| --- | --- | --- |
| `/v1/apps/...` routes, `apps` list key | Deprecated in Aug 2026 (still served) | `/v1/projects/...`, `projects` key |
| `cname` on create | Deprecated | `region` (`us-east-1`, `us-west-2`) or `cluster_name` |
| `storage_claim_size_gb` | Deprecated | `storage_size_gb` |
| `image_tag` on a non-Enterprise plan | Rejected (`403 image_tag_requires_enterprise`) | `update_channel` and `version` |
| `-models` image tags (e.g. `1.5.0-models`) | Removed in v2.0.0 | Omit `image_tag` (Enterprise: a tag from `/v1/container-images`) |
| Spicepod `version: v1beta1` | Removed in v2.0.0 | `version: v2` (`v1` still loads, auto-migrated) |

## Authentication

All endpoints except `GET /v1/health` take a Bearer token: a **personal access token** (create at [spice.ai/account/tokens](https://spice.ai/account/tokens), choosing the organization and scopes) or an **OAuth 2.0 client-credentials** access token (create the client under organization **Settings → OAuth Clients**).

```bash
# OAuth client credentials → access token (response: access_token, token_type, expires_in: 3600)
curl -X POST https://spice.ai/api/oauth/token \
  -H "Content-Type: application/json" \
  -d '{"client_id": "<client-id>", "client_secret": "<client-secret>", "grant_type": "client_credentials"}'

curl -H "Authorization: Bearer $SPICE_API_TOKEN" https://api.spice.ai/v1/projects
```

Required scopes are listed per endpoint below. A write scope includes its read scope, and `*` grants all. Project API keys authenticate the runtime data plane, not the Management API.

### Organization Context

A request acts on the organization the credential was minted against. Send `X-Org-Name: <org-handle>` to act on another: personal access tokens can name any organization the user belongs to, while OAuth clients are pinned to their own (`403 org_assertion_mismatch`). `GET /v1/orgs` (Aug 2026, scope `apps:read`) lists the caller's organizations with its role in each.

## Health Check

```bash
curl https://api.spice.ai/v1/health
# {"status":"ok","timestamp":"2026-09-17T15:13:40.251Z"}
```

No authentication required.

## Regions

List deployment regions. Pass the `region` value (`us-east-1` or `us-west-2`) when creating projects.

```bash
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/regions
```

**Scope:** `apps:read`

**Response:** `regions` (each with `name`, `region`, `provider`, `providerName`, `isDefault`, `disabled`) and `default`.

## Projects

Manage Spice.ai Cloud projects.

| Operation      | Method   | Path                             | Scope         |
| -------------- | -------- | -------------------------------- | ------------- |
| List projects  | `GET`    | `/v1/projects`                   | `apps:read`   |
| Create project | `POST`   | `/v1/projects`                   | `apps:write`  |
| Get project    | `GET`    | `/v1/projects/{projectId}`       | `apps:read`   |
| Update project | `PUT`    | `/v1/projects/{projectId}`       | `apps:write`  |
| Delete project | `DELETE` | `/v1/projects/{projectId}`       | `apps:delete` |
| Fork project   | `POST`   | `/v1/projects/{projectId}/forks` | `apps:write`  |
| List forks     | `GET`    | `/v1/projects/{projectId}/forks` | `apps:read`   |

### Create Project

```bash
curl -X POST https://api.spice.ai/v1/projects \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-project",
    "region": "us-west-2",
    "description": "Production analytics project",
    "visibility": "private"
  }'
```

| Field            | Type   | Required | Notes                                                                      |
| ---------------- | ------ | -------- | -------------------------------------------------------------------------- |
| `name`           | string | Yes      | 4–38 chars, letters/numbers/hyphens; unique per org (case-insensitive)     |
| `region`         | string | Yes*     | `us-east-1` or `us-west-2` (from `/v1/regions`)                            |
| `cluster_name`   | string | No       | Dedicated cluster from `GET /v1/clusters`; use instead of `region`         |
| `description`    | string | No       |                                                                            |
| `visibility`     | string | No       | `public` or `private` (default: `private`)                                 |
| `tags`           | object | No       | Key-value pairs                                                            |
| `update_channel` | string | No       | `stable`, `preview`, or `nightly`                                          |

\* Provide `region` or `cluster_name` for a Spice-managed project; omitting every placement field creates an unattached standalone (Cloud Connect) project. **Deprecated:** `cname` (an internal CNAME such as `us-east-1-prod-aws-data`) — use `region`.

**Status codes:** `201` created (the response includes `id` and the data-plane `endpoint`), `400` validation error, `409` name conflict, `429` rate limited

### Update Project

```bash
curl -X PUT https://api.spice.ai/v1/projects/{projectId} \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Updated description",
    "update_channel": "stable",
    "version": "2.x"
  }'
```

Updatable fields: `description`, `visibility`, `production_branch`, `tags`, `spicepod` (YAML string or JSON object), `update_channel` (`stable` | `preview` | `nightly`), `version` (runtime semver range, e.g. `2.x`), `image_tag`, `replicas`, `resources`, `executor`, `region`, `cluster_name`, `storage_size_gb` (**deprecated:** `storage_claim_size_gb`).

- Without an `image_tag` pin, each deployment resolves the runtime from `update_channel` and the `version` range. Stable can trail the latest OSS release — the [changelog](https://docs.spice.ai/changelog) lists the runtime each channel runs, so check it before relying on a new runtime feature.
- `image_tag` pins the runtime. It requires the Enterprise plan (`403 image_tag_requires_enterprise`) and must be a published version for the channel (`400 invalid_stable_image_tag`). Send `null` to clear a pin.
- `replicas` and `resources` are capped by plan limits (`GET /v1/limits`).

### Delete Project

```bash
curl -X DELETE https://api.spice.ai/v1/projects/{projectId} \
  -H "Authorization: Bearer $SPICE_API_TOKEN"
```

Deletes the project and tears down its runtime resources. Returns `204`.

### Fork Project (Sep 2026)

Create a new project from an existing project's configuration, in the same place or in another region or dedicated cluster. The fork keeps a link to its source: `GET /v1/projects/{projectId}` returns it as `forked_from` (`{"id", "name"}`, or `null` for a project that is not a fork), and `GET /v1/projects/{projectId}/forks` lists a project's forks. In the portal, fork from **Create Project → Fork a project** or the project's **Settings → Forks**.

```bash
curl -X POST https://api.spice.ai/v1/projects/123/forks \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "analytics-west", "region": "us-west-2"}'
```

| Field                      | Type   | Required               | Notes                                                                        |
| -------------------------- | ------ | ---------------------- | ---------------------------------------------------------------------------- |
| `name`                     | string | No                     | Defaults to `<source>-fork`, then `<source>-fork-2`, and so on              |
| `region`                   | string | No                     | `us-east-1` or `us-west-2`; omit it and `cluster_name` to fork in place      |
| `cluster_name`             | string | No                     | Dedicated cluster from `GET /v1/clusters`                                   |
| `scheduler_state_location` | string | For a distributed source | `s3://` URI that must not overlap the source's `runtime.scheduler.state_location` |

The body is optional, and any other field is rejected with `400`.

- **Copied:** the spicepod the source deploys (from its GitHub repository, the internal registry, or the stored config), linked connections, project secrets, linked organization secrets, update channel, version range, replica and executor counts, storage size, description, and tags. The platform-managed Postgres CDC replication slot is rebound to the fork.
- **Not copied:** API keys (the fork gets its own), deployments, the GitHub repository link, the instance size (the fork starts on the default instance), and visibility (forks are private).
- **GitHub-connected sources:** the spicepod is read from the source's repository, and a fork that cannot read it fails with `502 fork_source_repository_unreadable` instead of copying an older stored spicepod. The API copies only `spicepod.yaml`. It refuses a source that loads other files from the repository — component `ref`s, view `sql_ref`s, model or embedding `files`, or relative `file:` sources — with `422 fork_source_loads_repository_files`. To keep a fork in Git, fork the repository on GitHub, name the fork after the new project, then fork the project in the portal with **Deploy from a fork of the repository**. The portal connects the new project to that repository.
- **Not deployed:** the `201` response is the new project with its config. Deploy it with `POST /v1/projects/{forkId}/deployments`.
- **Check `shared_state` first.** The response lists settings copied as-is that name state the source also uses — a replication slot or Kafka consumer group the spicepod names, or a snapshot location. Two projects on one replication slot or consumer group split the changes between them, so change these in the fork's spicepod (`PUT /v1/projects/{forkId}`) before deploying unless the projects should share them.
- A source on a BYOC cluster or a self-hosted (Cloud Connect) runtime has no placement a fork can share, and neither does one whose region or cluster is no longer available: set `region` or `cluster_name`.

**Status codes:** `201` forked (not deployed), `400` validation error (codes in Troubleshooting), `402 ai_credits_exhausted` (the source runs on hosted AI credits the organization has used up), `404` source not found, `409` name taken or `fork_name_unavailable`, `422 fork_source_has_no_spicepod`, `fork_source_spicepod_invalid`, or `fork_source_loads_repository_files`, `429` rate limited, `502 fork_source_repository_unreadable`

## Deployments

Deploy the project's current spicepod.

| Operation         | Method | Path                                                  | Scope               |
| ----------------- | ------ | ----------------------------------------------------- | ------------------- |
| List deployments  | `GET`  | `/v1/projects/{projectId}/deployments`                | `deployments:read`  |
| Get deployment    | `GET`  | `/v1/projects/{projectId}/deployments/{deploymentId}` | `deployments:read`  |
| Create deployment | `POST` | `/v1/projects/{projectId}/deployments`                | `deployments:write` |

### List Deployments

```bash
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/projects/{projectId}/deployments?limit=10&status=succeeded"
```

| Parameter | Default | Description                                                       |
| --------- | ------- | ----------------------------------------------------------------- |
| `limit`   | 20      | Results per page (max 100), most recent first                     |
| `status`  | —       | Filter: `queued`, `in_progress`, `succeeded`, `failed`, `created` |

`created` marks a superseded historical record. A `failed` deployment carries `error_code` and `error_message`: `insufficient_cpu`, `insufficient_memory`, `insufficient_storage`, and `insufficient_instances` are retriable; `pod_exceeds_node_capacity`, `unable_to_start`, and `internal_error` are terminal.

### Create Deployment

```bash
curl -X POST https://api.spice.ai/v1/projects/{projectId}/deployments \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "branch": "main",
    "commit_sha": "abc123",
    "commit_message": "Add sales dataset"
  }'
```

| Field            | Type    | Required | Notes                                                    |
| ---------------- | ------- | -------- | -------------------------------------------------------- |
| `image_tag`      | string  | No       | Runtime tag override (Enterprise plan; published version) |
| `channel`        | string  | No       | `stable`, `preview`, or `nightly`                        |
| `replicas`       | integer | No       | 1-10                                                     |
| `branch`         | string  | No       | Source branch                                            |
| `commit_sha`     | string  | No       | Source commit                                            |
| `commit_message` | string  | No       | Deployment description                                   |
| `debug`          | boolean | No       | Enable debug mode                                        |

Returns `202` with the `queued` deployment; poll `GET .../deployments/{deploymentId}` for status. Returns `409` if a deployment is already in progress, and `400` if the project has no spicepod or is paused (resume with `POST /v1/projects/{projectId}/resume`).

## Secrets

Manage project secrets (encrypted at rest). Values are always masked in API responses. Deploy again for changes to reach the runtime.

| Operation     | Method   | Path                                         | Scope           |
| ------------- | -------- | -------------------------------------------- | --------------- |
| List secrets  | `GET`    | `/v1/projects/{projectId}/secrets`           | `secrets:read`  |
| Get secret    | `GET`    | `/v1/projects/{projectId}/secrets/{name}`    | `secrets:read`  |
| Create/Update | `POST`   | `/v1/projects/{projectId}/secrets`           | `secrets:write` |
| Delete secret | `DELETE` | `/v1/projects/{projectId}/secrets/{name}`    | `secrets:write` |

### Create or Update Secret

```bash
curl -X POST https://api.spice.ai/v1/projects/{projectId}/secrets \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "OPENAI_API_KEY", "value": "sk-..."}'
```

Upsert operation — creates if new, updates if exists. Name must start with a letter or underscore; letters, numbers, and underscores only. Reference it in the spicepod as `${secrets:OPENAI_API_KEY}`.

### Delete Secret

```bash
curl -X DELETE https://api.spice.ai/v1/projects/{projectId}/secrets/OPENAI_API_KEY \
  -H "Authorization: Bearer $SPICE_API_TOKEN"
```

## API Keys

Each project has two API keys (primary and secondary) for zero-downtime rotation. Regenerating a key immediately invalidates the old one.

| Operation      | Method | Path                                | Scope        |
| -------------- | ------ | ----------------------------------- | ------------ |
| Get API keys   | `GET`  | `/v1/projects/{projectId}/api-keys` | `apps:read`  |
| Regenerate key | `POST` | `/v1/projects/{projectId}/api-keys` | `apps:write` |

### Regenerate API Key

```bash
# Regenerate primary key (default)
curl -X POST https://api.spice.ai/v1/projects/{projectId}/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN"

# Regenerate secondary key ("key_number": 0 regenerates both)
curl -X POST https://api.spice.ai/v1/projects/{projectId}/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 2}'
```

`key_number`: `0` (both), `1` (primary, default), `2` (secondary). Responses return `api_key` (primary) and `api_key_2` (secondary).

### Using API Keys with Runtime

Runtime (data-plane) requests go to the project's `endpoint` (returned by `GET /v1/projects/{projectId}`, host e.g. `us-west-2-prod-aws-data.spiceai.io`), with the API key in the `X-API-Key` header. The host `data.spiceai.io` is a region-agnostic alias that only reaches `us-east-1` projects.

```bash
ENDPOINT="https://<project-endpoint-host>"  # the project's endpoint

# SQL query
curl "$ENDPOINT/v1/sql" \
  -H "X-API-Key: <api-key>" \
  -H "Content-Type: text/plain" \
  -d "SELECT * FROM my_dataset LIMIT 10"

# Chat (OpenAI-compatible; model is a name from the spicepod)
curl "$ENDPOINT/v1/chat/completions" \
  -H "X-API-Key: <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model": "my_model", "messages": [{"role":"user","content":"Hello"}]}'

# Search
curl "$ENDPOINT/v1/search" \
  -H "X-API-Key: <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"datasets": ["my_dataset"], "text": "search query"}'
```

## Members

Manage organization members. Roles: `owner`, `admin`, `member`, `viewer` (read-only). Managing members requires `admin` or `owner`; only owners can assign, change, or remove `admin` and `owner`. Owners cannot be modified or removed (`403`).

| Operation     | Method   | Path                     | Scope            |
| ------------- | -------- | ------------------------ | ---------------- |
| List members  | `GET`    | `/v1/members`            | `members:read`   |
| Add member    | `POST`   | `/v1/members`            | `members:write`  |
| Update roles  | `PATCH`  | `/v1/members/{memberId}` | `members:write`  |
| Remove member | `DELETE` | `/v1/members/{memberId}` | `members:delete` |

`{memberId}` is the member's `user_id`.

### Add Member

```bash
curl -X POST https://api.spice.ai/v1/members \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username": "jdoe", "roles": ["member"]}'
```

`roles` defaults to `["member"]`. The user needs an existing Spice.ai account (`404` if not found); returns `409` if already a member. Change roles with `PATCH` and a body of `{"roles": ["admin"]}`.

### Remove Member

```bash
curl -X DELETE https://api.spice.ai/v1/members/{memberId} \
  -H "Authorization: Bearer $SPICE_API_TOKEN"
```

## Container Images

List runtime image tags (the source of the Terraform `spiceai_container_images` data source). Only needed when pinning `image_tag`, which requires the Enterprise plan.

```bash
# Stable channel (default); use channel=enterprise for enterprise images
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/container-images?channel=stable"
```

**Scope:** `apps:read`

**Response:** `images` (each with `name`, `tag`, `channel`) and `default` (the default tag). Use a returned `tag` as `image_tag` rather than guessing one.

## Common Workflows

### Create and Deploy a Project

```bash
# 1. List regions
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/regions

# 2. Create project
curl -X POST https://api.spice.ai/v1/projects \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "analytics-project", "region": "us-west-2"}'

# 3. Add secrets (use the project ID from step 2)
curl -X POST https://api.spice.ai/v1/projects/123/secrets \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "PG_PASS", "value": "secret123"}'

# 4. Set the spicepod (YAML string or JSON object)
curl -X PUT https://api.spice.ai/v1/projects/123 \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"spicepod": {"version": "v2", "kind": "Spicepod", "name": "analytics-project",
       "datasets": [{"from": "postgres:public.orders", "name": "orders",
         "params": {"pg_host": "db.example.com", "pg_user": "analytics", "pg_pass": "${secrets:PG_PASS}"}}]}}'

# 5. Deploy
curl -X POST https://api.spice.ai/v1/projects/123/deployments \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"branch": "main", "commit_message": "Initial deployment"}'

# 6. Check deployment status (or GET .../deployments/{deploymentId})
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/projects/123/deployments?limit=1"
```

### Copy or Move a Project to Another Region

```bash
# 1. Fork project 123 into us-west-2. Note the fork's "id" and read "shared_state".
curl -X POST https://api.spice.ai/v1/projects/123/forks \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "analytics-west", "region": "us-west-2"}'

# 2. If shared_state lists anything, update the fork's spicepod first (PUT /v1/projects/456).

# 3. Deploy the fork (id 456 here)
curl -X POST https://api.spice.ai/v1/projects/456/deployments \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"commit_message": "Initial deployment of the fork"}'

# 4. Wait for the deployment to succeed
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/projects/456/deployments?limit=1"
```

Clients then use the fork's `endpoint` and API keys (`GET /v1/projects/456/api-keys`); the source's keys do not work on the fork. To finish a move, delete the source with `DELETE /v1/projects/123` — only after the user confirms, because deleting tears down the source's runtime.

### Rotate API Keys (Zero Downtime)

```bash
# 1. Get current keys
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/projects/123/api-keys

# 2. Regenerate secondary key
curl -X POST https://api.spice.ai/v1/projects/123/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 2}'

# 3. Update clients to use new secondary key
# 4. Regenerate primary key
curl -X POST https://api.spice.ai/v1/projects/123/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 1}'
```

## Using the Helper Script

A helper script is bundled at `scripts/spice-cloud.sh` (relative to this skill directory) for common operations. It calls the canonical `/v1/projects` routes; the older `*-app` command names still work as aliases.

```bash
# Set your token (personal access token or OAuth access token)
export SPICE_API_TOKEN="your-token"

# List projects (JSON under "projects")
bash scripts/spice-cloud.sh list-projects

# Create project
bash scripts/spice-cloud.sh create-project my-project us-west-2

# Fork project 123 as analytics-west in us-west-2 (name and region are optional)
bash scripts/spice-cloud.sh fork-project 123 analytics-west us-west-2

# List the forks of project 123
bash scripts/spice-cloud.sh list-forks 123

# Deploy project
bash scripts/spice-cloud.sh deploy 123

# Add secret
bash scripts/spice-cloud.sh add-secret 123 DB_PASSWORD secret123

# List deployments
bash scripts/spice-cloud.sh list-deployments 123

# Get API keys
bash scripts/spice-cloud.sh get-api-keys 123
```

## Present Results to User

When presenting management API results:
- Show project IDs and names in a table for list operations
- For a fork, name the project it was forked from, say it is not deployed yet, and list any `shared_state` settings
- Show deployment status clearly (queued/in_progress/succeeded/failed), with `error_code` and `error_message` for failures
- Never display secret values — confirm creation/update only
- Show API keys with a warning about secure storage
- Give the project's data-plane `endpoint` for queries, and link the portal as `https://spice.ai/<org>/<project>`

## Troubleshooting

| Issue                               | Solution                                                                                    |
| ----------------------------------- | ------------------------------------------------------------------------------------------- |
| `401 Unauthorized`                  | Check `$SPICE_API_TOKEN` is a valid PAT, or an OAuth access token within its `expires_in`   |
| `403` `insufficient_scope`          | Reissue the token or OAuth client with the scope from the endpoint tables above             |
| `403` `forbidden` / `org_forbidden` | Role too low (viewers are read-only) / `X-Org-Name` names an org the caller can't reach    |
| `403 image_tag_requires_enterprise` | Omit `image_tag`; select the runtime with `update_channel` and `version` instead            |
| `404 Project not found`             | Verify `projectId` with `GET /v1/projects` in the right organization                        |
| `409 Conflict` on create project    | Project name already exists (names compare case-insensitively)                              |
| `400 fork_placement_required`       | The source runs on a BYOC cluster, a self-hosted runtime, or a region or cluster that is gone; set `region` or `cluster_name` for the fork |
| `400 scheduler_state_location_*`    | The source is distributed; set `scheduler_state_location` to an `s3://` URI outside the source's (`_required`, `_unsupported`, `_overlaps_source`). `_not_applicable` means the source is not distributed, so omit the field |
| `409 fork_name_unavailable`         | Every default `<source>-fork-N` name is taken; set `name`                                   |
| `422 fork_source_has_no_spicepod` / `fork_source_spicepod_invalid` | The source has no spicepod or an invalid one; fix the source's spicepod, then fork again |
| `422 fork_source_loads_repository_files` | The source's spicepod loads other files from its GitHub repository; fork the repository on GitHub, then fork the project in the portal, which deploys from the forked repository |
| `502 fork_source_repository_unreadable` | The source's spicepod could not be read from its GitHub repository; retry, or fix the repository or the GitHub App's access to it |
| `409` on deployment                 | A deployment is already in progress; wait for it to complete                                |
| `400` on deployment                 | Project has no spicepod, is paused (`POST .../resume`), or `image_tag` isn't a published version for the channel |
| `400` on create secret              | Secret name must start with letter/underscore; letters, numbers, underscores only           |
| Deployment `failed`                 | Check `error_code`: `insufficient_*` codes are retriable; the others are terminal           |
| Runtime requests fail for a `us-west-2` project | Send them to the project's `endpoint`; `data.spiceai.io` only reaches `us-east-1`  |

## Documentation

- [Management API Reference](https://docs.spice.ai/api/management-api/management)
- [OpenAPI Specification](https://api.spice.ai/openapi.json)
- [Runtime API Reference](https://docs.spice.ai/api)
- [Spice.ai Cloud Changelog](https://docs.spice.ai/changelog)
- [Spice.ai Cloud](https://spice.ai)
