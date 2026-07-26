---
name: spice-cloud-management
description: Manage Spice.ai Cloud resources via the Management API — apps, deployments, secrets, API keys, and org members. Use this skill whenever the user wants to create or manage a Spice.ai Cloud app, trigger a deployment, manage cloud secrets or API keys, list regions or runtime versions, add/remove org members, or automate any Spice.ai Cloud operation. Also use when the user mentions "spice.ai cloud", "deploy to spice", "cloud API", or wants to use the Spice.ai hosted platform. For infrastructure-as-code with Terraform, see spice-terraform.
---

# Spice.ai Cloud Management

Manage Spice.ai Cloud resources through the Management API at `https://api.spice.ai`. Create apps, trigger deployments, manage secrets and API keys, and administer organization members.

## Authentication

All endpoints (except `/v1/health`) require a Bearer token:

```bash
curl -H "Authorization: Bearer $SPICE_API_TOKEN" https://api.spice.ai/v1/apps
```

Get your token from [spice.ai/account](https://spice.ai/account). Required scopes vary by endpoint (see tables below).

## Base URL

```
https://api.spice.ai
```

## Health Check

```bash
curl https://api.spice.ai/v1/health
# {"status":"ok","timestamp":"2024-01-15T10:30:00.000Z"}
```

No authentication required.

## Regions

List available deployment regions. Use the `cname` value when creating apps.

```bash
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/regions
```

**Scope:** `apps:read`

**Response:**

```json
{
  "regions": [
    {
      "name": "US West",
      "region": "us-west-2",
      "cname": "us-west-2",
      "provider": "aws",
      "providerName": "Amazon Web Services"
    }
  ],
  "default": "us-west-2"
}
```

## Apps

Manage Spice.ai Cloud applications.

| Operation  | Method   | Path               | Scope         |
| ---------- | -------- | ------------------ | ------------- |
| List apps  | `GET`    | `/v1/apps`         | `apps:read`   |
| Create app | `POST`   | `/v1/apps`         | `apps:write`  |
| Get app    | `GET`    | `/v1/apps/{appId}` | `apps:read`   |
| Update app | `PUT`    | `/v1/apps/{appId}` | `apps:write`  |
| Delete app | `DELETE` | `/v1/apps/{appId}` | `apps:delete` |

### Create App

```bash
curl -X POST https://api.spice.ai/v1/apps \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-app",
    "cname": "us-west-2",
    "description": "Production analytics app",
    "visibility": "private"
  }'
```

| Field          | Type   | Required | Notes                                   |
| -------------- | ------ | -------- | --------------------------------------- |
| `name`         | string | Yes      | Min 4 chars, alphanumeric + hyphens     |
| `cname`        | string | Yes      | Region identifier (from `/v1/regions`)  |
| `description`  | string | No       |                                         |
| `visibility`   | string | No       | `public` or `private`                   |
| `tags`         | object | No       | Key-value pairs                         |

**Status codes:** `201` created, `400` validation error, `409` name conflict

### Update App

```bash
curl -X PUT https://api.spice.ai/v1/apps/{appId} \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Updated description",
    "replicas": 3,
    "image_tag": "1.5.0-models"
  }'
```

Updatable fields: `description`, `visibility`, `production_branch`, `tags`, `spicepod`, `image_tag`, `image`, `registry`, `update_channel`, `replicas` (1-10), `region`, `node_group`, `storage_claim_size_gb`

### Delete App

```bash
curl -X DELETE https://api.spice.ai/v1/apps/{appId} \
  -H "Authorization: Bearer $SPICE_API_TOKEN"
```

Soft-deletes the app and stops all running deployments. Returns `204`.

## Deployments

Deploy and manage app instances.

| Operation         | Method | Path                              | Scope              |
| ----------------- | ------ | --------------------------------- | ------------------ |
| List deployments  | `GET`  | `/v1/apps/{appId}/deployments`    | `deployments:read` |
| Create deployment | `POST` | `/v1/apps/{appId}/deployments`    | `deployments:write`|

### List Deployments

```bash
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/apps/{appId}/deployments?limit=10&status=succeeded"
```

| Parameter | Default | Description                                               |
| --------- | ------- | --------------------------------------------------------- |
| `limit`   | 20      | Results per page (max 100)                                |
| `status`  | —       | Filter: `queued`, `in_progress`, `succeeded`, `failed`, `created` |

### Create Deployment

```bash
curl -X POST https://api.spice.ai/v1/apps/{appId}/deployments \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "branch": "main",
    "commit_sha": "abc123",
    "commit_message": "Add sales dataset"
  }'
```

| Field            | Type    | Required | Notes                  |
| ---------------- | ------- | -------- | ---------------------- |
| `image_tag`      | string  | No       | Runtime version tag    |
| `replicas`       | integer | No       | 1-10                   |
| `branch`         | string  | No       | Source branch           |
| `commit_sha`     | string  | No       | Source commit           |
| `commit_message` | string  | No       | Deployment description |
| `debug`          | boolean | No       | Enable debug mode      |

Returns `202` with status `queued`. Returns `409` if a deployment is already in progress.

## Secrets

Manage app secrets (AES-256 encrypted at rest, TLS 1.3 in transit). Values are always masked in API responses.

| Operation       | Method   | Path                                     | Scope           |
| --------------- | -------- | ---------------------------------------- | --------------- |
| List secrets    | `GET`    | `/v1/apps/{appId}/secrets`               | `secrets:read`  |
| Get secret      | `GET`    | `/v1/apps/{appId}/secrets/{secretName}`  | `secrets:read`  |
| Create/Update   | `POST`   | `/v1/apps/{appId}/secrets`               | `secrets:write` |
| Delete secret   | `DELETE` | `/v1/apps/{appId}/secrets/{secretName}`  | `secrets:write` |

### Create or Update Secret

```bash
curl -X POST https://api.spice.ai/v1/apps/{appId}/secrets \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "OPENAI_API_KEY", "value": "sk-..."}'
```

Upsert operation — creates if new, updates if exists. Name must start with a letter or underscore; alphanumeric and underscores only.

### Delete Secret

```bash
curl -X DELETE https://api.spice.ai/v1/apps/{appId}/secrets/OPENAI_API_KEY \
  -H "Authorization: Bearer $SPICE_API_TOKEN"
```

## API Keys

Each app has two API keys (primary and secondary) for zero-downtime rotation.

| Operation      | Method | Path                          | Scope        |
| -------------- | ------ | ----------------------------- | ------------ |
| Get API keys   | `GET`  | `/v1/apps/{appId}/api-keys`   | `apps:read`  |
| Regenerate key | `POST` | `/v1/apps/{appId}/api-keys`   | `apps:write` |

### Regenerate API Key

```bash
# Regenerate primary key (default)
curl -X POST https://api.spice.ai/v1/apps/{appId}/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN"

# Regenerate secondary key
curl -X POST https://api.spice.ai/v1/apps/{appId}/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 2}'

# Regenerate both
curl -X POST https://api.spice.ai/v1/apps/{appId}/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 0}'
```

`key_number`: `0` (both), `1` (primary, default), `2` (secondary)

### Using API Keys with Runtime

```bash
# SQL query
curl -H "x-api-key: <api-key>" https://data.spiceai.io/v1/sql \
  -d "SELECT * FROM my_dataset LIMIT 10"

# Chat (OpenAI-compatible)
curl https://data.spiceai.io/v1/chat/completions \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4", "messages": [{"role":"user","content":"Hello"}]}'

# Search
curl https://data.spiceai.io/v1/search \
  -H "x-api-key: <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"datasets": ["my_dataset"], "text": "search query"}'
```

## Members

Manage organization members. Currently all members have full access; role-based access control is planned.

| Operation     | Method   | Path                     | Scope            |
| ------------- | -------- | ------------------------ | ---------------- |
| List members  | `GET`    | `/v1/members`            | `members:read`   |
| Add member    | `POST`   | `/v1/members`            | `members:write`  |
| Remove member | `DELETE` | `/v1/members/{memberId}` | `members:delete` |

### Add Member

```bash
curl -X POST https://api.spice.ai/v1/members \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username": "jdoe", "roles": ["member"]}'
```

Roles: `owner`, `member`, `billing`. User must have signed in to Spice.ai at least once. Returns `404` if user not found, `409` if already a member.

### Remove Member

```bash
curl -X DELETE https://api.spice.ai/v1/members/{memberId} \
  -H "Authorization: Bearer $SPICE_API_TOKEN"
```

Cannot remove the organization owner (`403`).

## Container Images

List available Spice runtime versions for deployments.

```bash
# Stable channel (default)
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/container-images

# Enterprise channel
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/container-images?channel=enterprise"
```

**Scope:** `apps:read`

**Response:**

```json
{
  "images": [
    {"name": "spiceai/spiceai:1.5.0-models", "tag": "1.5.0-models", "channel": "stable"}
  ],
  "default": "1.5.0-models"
}
```

Use the `tag` value in app `image_tag` configuration or deployment requests.

## Common Workflows

### Create and Deploy an App

```bash
# 1. List regions
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/regions

# 2. Create app
curl -X POST https://api.spice.ai/v1/apps \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "analytics-app", "cname": "us-west-2"}'

# 3. Add secrets (use the app ID from step 2)
curl -X POST https://api.spice.ai/v1/apps/123/secrets \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "PG_PASS", "value": "secret123"}'

# 4. Deploy
curl -X POST https://api.spice.ai/v1/apps/123/deployments \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"branch": "main", "commit_message": "Initial deployment"}'

# 5. Check deployment status
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  "https://api.spice.ai/v1/apps/123/deployments?limit=1"
```

### Rotate API Keys (Zero Downtime)

```bash
# 1. Get current keys
curl -H "Authorization: Bearer $SPICE_API_TOKEN" \
  https://api.spice.ai/v1/apps/123/api-keys

# 2. Regenerate secondary key
curl -X POST https://api.spice.ai/v1/apps/123/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 2}'

# 3. Update clients to use new secondary key
# 4. Regenerate primary key
curl -X POST https://api.spice.ai/v1/apps/123/api-keys \
  -H "Authorization: Bearer $SPICE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"key_number": 1}'
```

## Using the Helper Script

A helper script is bundled at `scripts/spice-cloud.sh` (relative to this skill directory) for common operations.

```bash
# Set your API token
export SPICE_API_TOKEN="your-token"

# List apps
bash scripts/spice-cloud.sh list-apps

# Create app
bash scripts/spice-cloud.sh create-app my-app us-west-2

# Deploy app
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
- Show app IDs and names in a table for list operations
- Show deployment status clearly (queued/in_progress/succeeded/failed)
- Never display secret values — confirm creation/update only
- Show API keys with a warning about secure storage
- Include the app URL format: `https://<app-name>.spice.ai`

## Troubleshooting

| Issue                        | Solution                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------- |
| `401 Unauthorized`           | Check `$SPICE_API_TOKEN` is set and valid; get a new token from spice.ai      |
| `403 Forbidden`              | Token lacks required scope; check scope column in endpoint tables above       |
| `404 App not found`          | Verify `appId` with `GET /v1/apps`; app may have been deleted                 |
| `409 Conflict` on create app | App name already exists; choose a different name                              |
| `409` on deployment          | A deployment is already in progress; wait for it to complete                  |
| `400` on create secret       | Secret name must start with letter/underscore, alphanumeric + underscores only|
| Deployment stays `queued`    | Check app has a valid spicepod configured; verify image_tag exists            |

## Documentation

- [Management API Reference](https://docs.spice.ai/api/management-api)
- [Interactive API Docs](https://api.spice.ai/v1/docs)
- [Spice.ai Cloud](https://spice.ai)
