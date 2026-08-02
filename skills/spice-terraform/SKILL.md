---
name: spice-terraform
description: Manage Spice.ai Cloud infrastructure as code with Terraform or OpenTofu using the spiceai/spiceai provider. Use this skill whenever the user wants to write Terraform/OpenTofu configs for Spice apps, deployments, secrets, or org members, import existing Spice.ai resources into Terraform state, set up OAuth authentication for the provider, or use Terraform data sources for regions and container images. Also use when the user mentions "terraform" and "spice" together, or wants IaC for their Spice.ai Cloud infrastructure. For direct API management without Terraform, see spice-cloud-management.
---

# Spice.ai Terraform Provider

Manage Spice.ai Cloud resources as infrastructure-as-code using the `spiceai/spiceai` Terraform provider. Supports apps, deployments, secrets, org members, and data sources for regions and runtime images.

## Provider Setup

```hcl
terraform {
  required_providers {
    spiceai = {
      source  = "spiceai/spiceai"
      version = "~> 0.1"
    }
  }
}

provider "spiceai" {
  client_id     = var.spiceai_client_id
  client_secret = var.spiceai_client_secret
  # api_endpoint = "https://api.spice.ai"  # optional, this is the default
}
```

**Requirements:** Terraform >= 1.0 or OpenTofu >= 1.0

### Authentication

The provider uses OAuth 2.0 Client Credentials. Set credentials via:

1. **Provider block** — `client_id` and `client_secret` arguments
2. **Environment variables** — `SPICEAI_CLIENT_ID` and `SPICEAI_CLIENT_SECRET`

Create OAuth clients in the Spice.ai Portal: **Settings > OAuth Clients**.

```bash
export SPICEAI_CLIENT_ID="your-client-id"
export SPICEAI_CLIENT_SECRET="your-client-secret"
terraform plan
```

## Resources

### spiceai_app

Manages a Spice.ai application.

```hcl
data "spiceai_regions" "available" {}

resource "spiceai_app" "analytics" {
  name        = "analytics-app"
  cname       = data.spiceai_regions.available.default
  description = "Production analytics"
  visibility  = "private"
  replicas    = 2
  image_tag   = "1.5.0-models"

  spicepod = yamlencode({
    version = "v1"
    kind    = "Spicepod"
    name    = "analytics-app"
    datasets = [{
      from = "postgres:public.events"
      name = "events"
      params = {
        pg_host = "db.example.com"
        pg_user = "$${secrets:PG_USER}"
        pg_pass = "$${secrets:PG_PASS}"
      }
      acceleration = {
        enabled              = true
        engine               = "duckdb"
        refresh_check_interval = "5m"
      }
    }]
  })
}
```

**Arguments:**

| Argument                | Type   | Required | Notes                                       |
| ----------------------- | ------ | -------- | ------------------------------------------- |
| `name`                  | string | Yes      | Min 4 chars, alphanumeric + hyphens         |
| `cname`                 | string | Yes      | Region identifier (from `spiceai_regions`)  |
| `description`           | string | No       |                                             |
| `visibility`            | string | No       | `public` or `private` (default: `private`)  |
| `spicepod`              | string | No       | YAML or JSON spicepod configuration         |
| `image_tag`             | string | No       | Spice runtime version tag                   |
| `replicas`              | number | No       | 1-10                                        |
| `region`                | string | No       | AWS region code                             |
| `production_branch`     | string | No       | Git branch for production deployments       |
| `node_group`            | string | No       | Kubernetes node group                       |
| `storage_claim_size_gb` | number | No       | Persistent volume size in GB                |

**Read-only attributes:** `id`, `api_key` (sensitive), `created_at`

### spiceai_deployment

Creates an immutable deployment for an app. Use `triggers` to auto-redeploy on config changes.

```hcl
resource "spiceai_deployment" "current" {
  app_id         = spiceai_app.analytics.id
  commit_message = "Deploy analytics app"

  triggers = {
    spicepod  = spiceai_app.analytics.spicepod
    image_tag = spiceai_app.analytics.image_tag
    replicas  = spiceai_app.analytics.replicas
  }
}
```

**Arguments:**

| Argument         | Type    | Required | Notes                              |
| ---------------- | ------- | -------- | ---------------------------------- |
| `app_id`         | string  | Yes      | App ID to deploy                   |
| `image_tag`      | string  | No       | Override runtime image             |
| `replicas`       | number  | No       | Override replicas (1-10)           |
| `debug`          | boolean | No       | Enable debug mode (default: false) |
| `branch`         | string  | No       | Git branch for tracking            |
| `commit_sha`     | string  | No       | Git commit SHA                     |
| `commit_message` | string  | No       | Deployment description             |

**Read-only attributes:** `id`, `status` (`queued` | `in_progress` | `succeeded` | `failed`), `error_message`, `created_at`

The `triggers` map causes Terraform to replace the deployment whenever any tracked value changes.

### spiceai_secret

Manages app secrets. Values are AES-256 encrypted at rest.

```hcl
variable "secrets" {
  type      = map(string)
  sensitive = true
  default = {
    PG_USER       = "analytics"
    PG_PASS       = "secret123"
    OPENAI_API_KEY = "sk-..."
  }
}

resource "spiceai_secret" "app_secrets" {
  for_each = var.secrets

  app_id = spiceai_app.analytics.id
  name   = each.key
  value  = each.value
}
```

**Arguments:**

| Argument | Type   | Required | Notes                                               |
| -------- | ------ | -------- | --------------------------------------------------- |
| `app_id` | string | Yes      |                                                     |
| `name`   | string | Yes      | Start with letter/underscore, alphanumeric + `_`    |
| `value`  | string | Yes      | Sensitive. Must set manually after import (API masks values) |

**Read-only attributes:** `id`

### spiceai_member

Manages organization members by GitHub username.

```hcl
variable "team" {
  type    = set(string)
  default = ["alice", "bob"]
}

resource "spiceai_member" "team" {
  for_each = var.team

  username = each.key
  roles    = ["member"]
}
```

**Arguments:**

| Argument   | Type     | Required | Notes                              |
| ---------- | -------- | -------- | ---------------------------------- |
| `username` | string   | Yes      | GitHub username                    |
| `roles`    | string[] | No       | Default: `["member"]`. Options: `owner`, `member`, `billing` |

**Read-only attributes:** `user_id`

Organization owners cannot be managed via Terraform.

## Data Sources

### spiceai_regions

```hcl
data "spiceai_regions" "available" {}

# Use: data.spiceai_regions.available.default
# Use: data.spiceai_regions.available.regions[*].cname
```

Returns `regions` list (each with `name`, `region`, `cname`, `provider`, `providerName`) and `default` region.

### spiceai_container_images

```hcl
data "spiceai_container_images" "stable" {
  channel = "stable"  # or "enterprise"
}

# Use: data.spiceai_container_images.stable.default
# Use: data.spiceai_container_images.stable.images[*].tag
```

Returns `images` list (each with `name`, `tag`, `channel`) and `default` tag.

### spiceai_app (data)

```hcl
data "spiceai_app" "existing" {
  id = 12345
}
```

Retrieves details of an existing app by ID.

### spiceai_apps

```hcl
data "spiceai_apps" "all" {}

# Filter in Terraform
locals {
  prod_apps = [for app in data.spiceai_apps.all.apps : app if app.visibility == "private"]
}
```

Lists all apps in the organization.

### spiceai_members

```hcl
data "spiceai_members" "all" {}
```

Lists all organization members with `username`, `roles`, `is_owner`, and `user_id`.

### spiceai_secrets

```hcl
data "spiceai_secrets" "app" {
  app_id = spiceai_app.analytics.id
}
```

Lists secrets for an app. Values are always masked.

## Import

Import existing resources into Terraform state:

```bash
# App (by app ID)
terraform import spiceai_app.analytics 12345

# Deployment (appId/deploymentId)
terraform import spiceai_deployment.current 12345/67890

# Secret (appId/SECRET_NAME)
terraform import spiceai_secret.db_password 12345/DB_PASSWORD

# Member (by user ID)
terraform import spiceai_member.alice 789

# Member with for_each
terraform import 'spiceai_member.team["alice"]' 789
```

After importing `spiceai_secret`, manually set the `value` in your config — the API never returns plain-text values.

## Complete Example

```hcl
terraform {
  required_providers {
    spiceai = {
      source  = "spiceai/spiceai"
      version = "~> 0.1"
    }
  }
}

provider "spiceai" {}

# Look up available regions and runtime versions
data "spiceai_regions" "available" {}
data "spiceai_container_images" "stable" {
  channel = "stable"
}

# Create the app
resource "spiceai_app" "myapp" {
  name      = "my-analytics"
  cname     = data.spiceai_regions.available.default
  image_tag = data.spiceai_container_images.stable.default

  spicepod = yamlencode({
    version  = "v1"
    kind     = "Spicepod"
    name     = "my-analytics"
    datasets = [{
      from = "postgres:public.events"
      name = "events"
      params = {
        pg_host = "db.example.com"
        pg_user = "$${secrets:PG_USER}"
        pg_pass = "$${secrets:PG_PASS}"
      }
    }]
    models = [{
      from = "openai:gpt-4o"
      name = "assistant"
      params = {
        openai_api_key = "$${secrets:OPENAI_API_KEY}"
      }
    }]
  })
}

# Manage secrets
variable "app_secrets" {
  type      = map(string)
  sensitive = true
}

resource "spiceai_secret" "secrets" {
  for_each = var.app_secrets
  app_id   = spiceai_app.myapp.id
  name     = each.key
  value    = each.value
}

# Deploy (redeploys when app config changes)
resource "spiceai_deployment" "current" {
  app_id         = spiceai_app.myapp.id
  commit_message = "Managed by Terraform"

  triggers = {
    spicepod  = spiceai_app.myapp.spicepod
    image_tag = spiceai_app.myapp.image_tag
  }

  depends_on = [spiceai_secret.secrets]
}

# Team access
resource "spiceai_member" "team" {
  for_each = toset(["alice", "bob"])
  username = each.key
}

# Outputs
output "app_id" {
  value = spiceai_app.myapp.id
}

output "api_key" {
  value     = spiceai_app.myapp.api_key
  sensitive = true
}

output "deployment_status" {
  value = spiceai_deployment.current.status
}
```

## Present Results to User

When generating Terraform configurations:
- Use `data.spiceai_regions` for region lookup instead of hardcoding
- Use `data.spiceai_container_images` for image tags instead of hardcoding
- Always use `for_each` for multiple secrets or members
- Mark secret values and API keys as `sensitive`
- Include `triggers` on deployments to auto-redeploy on changes
- Use `depends_on` to ensure secrets exist before deploying
- Reference secrets in spicepod with `$${secrets:NAME}` (double `$` for Terraform escaping)

## Troubleshooting

| Issue                                  | Solution                                                                        |
| -------------------------------------- | ------------------------------------------------------------------------------- |
| `401` or auth errors                   | Verify `SPICEAI_CLIENT_ID` / `SPICEAI_CLIENT_SECRET`; check OAuth client scope  |
| Import loses secret value              | Expected — set `value` in config after import; API always masks values           |
| Deployment stuck in `queued`           | Check app has a valid `spicepod`; verify `image_tag` exists                     |
| `409` on deployment                    | Previous deployment still in progress; wait or check status                     |
| Spicepod YAML syntax errors            | Use `yamlencode()` for type safety; validate YAML before applying               |
| `$$` showing in spicepod               | Use `$${secrets:NAME}` in Terraform — the double `$` escapes to single `$`     |
| Cannot delete org owner                | Organization owners cannot be managed by Terraform; remove manually             |
| Provider not found                     | Check `source = "spiceai/spiceai"` and run `terraform init`                     |

## Documentation

- [Terraform Provider Docs](https://docs.spice.ai/api/management-api/terraform)
- [Terraform Registry](https://registry.terraform.io/providers/spiceai/spiceai/latest)
- [GitHub Repository](https://github.com/spiceai/terraform-provider-spiceai)
- [Spice.ai Management API](https://docs.spice.ai/api/management-api)
