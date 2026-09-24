---
name: spice-secrets
description: Configure secret stores in Spice — environment variables, Kubernetes, AWS Secrets Manager, Azure Key Vault, HashiCorp Vault, and OS keyring. Use this skill whenever the user needs to manage credentials, API keys, passwords, or tokens in Spice, reference secrets in spicepod.yaml params with ${ store:KEY } syntax, set up .env files, configure secret store precedence, or understand how the `secrets:` section works. Also use when the user asks how to pass database passwords or API keys securely to Spice datasets or models.
---

# Spice Secret Stores

Secret stores manage sensitive data like API keys, passwords, and tokens. The `env` store is loaded by default.

## Version Compatibility

Written for **Spice v2.3.x** (checked against v2.3.2). Check the user's runtime version before recommending configuration:

- **Find it**: `spice version` (CLI and runtime), `spiced --version`, or the image tag (`spiceai/spiceai:<tag>`, Helm `image.tag`). Not the runtime version: `version: v2` in `spicepod.yaml` (manifest schema) or SQL `version()` (DataFusion).
- **Markers**: unmarked content applies to v2.0.0 and later. Later additions are marked `(vX.Y.Z+)`; changes are marked **Removed**, **Deprecated**, **Changed**, or **Breaking in vX.Y.Z**.
- **Older runtime**: don't recommend a newer feature — offer `spice upgrade` or an alternative — and read that release line's docs, e.g. `https://spiceai.org/docs/v2.2/...` (`/docs/next/` tracks trunk, not a release). On v1.x, use the [v1.11 docs](https://spiceai.org/docs/v1.11) and the [v2.0 upgrade guide](https://spiceai.org/releases/v2.0-stable#upgrade-guide-from-v1x).
- **Newer runtime**: check the [release notes](https://spiceai.org/releases) for changes after v2.3.2.

| Old | Change | Use instead |
| --- | --- | --- |
| Unknown or misspelled store `params` (e.g. `aws_region`) | Rejected at load since v2.0.0 | The documented names (e.g. `region`) |

## Basic Configuration

```yaml
secrets:
  - from: <store_type>
    name: <store_name>
```

## Supported Secret Stores

| Store | From Format | Description |
|-------|-------------|-------------|
| Environment | `env` | Environment variables + `.env` / `.env.local` files (default) |
| Kubernetes | `kubernetes:<secret_name>` | Kubernetes secrets |
| AWS Secrets Manager | `aws_secrets_manager:<secret_name>` | Keys inside one secret; params `region`, `endpoint_url`, `key`, `secret`, `session_token` |
| Azure Key Vault | `azure_keyvault:<vault_name>` | `auth_method`: `service_principal`, `managed_identity`, `workload_identity`, `cli`, or `default` |
| HashiCorp Vault | `hashicorp_vault:<path>` | KV v1/v2; `token`, `approle`, `kubernetes`, `jwt` auth (Spice.ai Enterprise) |
| Keyring | `keyring` | OS keyring (macOS Keychain, Linux secret-service, Windows Credential Manager); entries with account `spiced` |

The selector after `:` is required for `kubernetes`, `aws_secrets_manager`, `azure_keyvault`, and
`hashicorp_vault`. Unknown `params` are rejected with an error listing the supported names, which
catches typos immediately instead of silently ignoring them.

## Default: Environment Variables

Loaded automatically. Reads from environment variables and any `.env.local` or `.env` files in the project directory (`.env.local` takes precedence over `.env`).

```yaml
secrets:
  - from: env
    name: env
```

## Referencing Secrets

Use `${ store_name:KEY_NAME }` syntax in component parameters:

```yaml
datasets:
  - from: postgres:my_table
    name: my_table
    params:
      pg_user: ${ env:PG_USER }
      pg_pass: ${ env:PG_PASSWORD }

models:
  - from: openai:gpt-4o
    name: gpt4
    params:
      openai_api_key: ${ secrets:OPENAI_API_KEY }
```

Also works within strings:

```yaml
params:
  mysql_connection_string: mysql://${env:USER}:${env:PASSWORD}@localhost:3306/db
```

## Searching All Stores

Use `${ secrets:KEY }` to search all configured stores in precedence order (last defined wins):

```yaml
secrets:
  - from: env
    name: env
  - from: keyring
    name: keyring

datasets:
  - from: postgres:my_table
    name: my_table
    params:
      pg_user: ${ secrets:pg_user }     # checks keyring first, then env
      pg_pass: ${ secrets:pg_pass }
```

The `<key_name>` is automatically uppercased for the `env` secret store.

## Examples

### Kubernetes Secrets

```yaml
secrets:
  - from: kubernetes:my-app-secrets
    name: k8s
```

### AWS Secrets Manager

```yaml
secrets:
  - from: aws_secrets_manager:my_secret_name # ${ aws:my_key } reads key `my_key` in this secret
    name: aws
    params:
      region: us-east-1 # optional; falls back to the AWS SDK default chain
```

### Override Order (env overrides keyring)

```yaml
secrets:
  - from: keyring
    name: keyring
  - from: env
    name: env
```

## Documentation

- [Secret Stores](https://spiceai.org/docs/components/secret-stores)
- [Environment Secret Store](https://spiceai.org/docs/components/secret-stores/env)
- [Kubernetes Secret Store](https://spiceai.org/docs/components/secret-stores/kubernetes)
- [AWS Secrets Manager](https://spiceai.org/docs/components/secret-stores/aws-secrets-manager)
- [Azure Key Vault](https://spiceai.org/docs/components/secret-stores/azure-keyvault)
- [HashiCorp Vault](https://spiceai.org/docs/components/secret-stores/hashicorp-vault)
- [Keyring Secret Store](https://spiceai.org/docs/components/secret-stores/keyring)
