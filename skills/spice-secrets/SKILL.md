---
name: spice-secrets
description: Configure secret stores in Spice — environment variables, Kubernetes, AWS Secrets Manager, and OS keyring. Use this skill whenever the user needs to manage credentials, API keys, passwords, or tokens in Spice, reference secrets in spicepod.yaml params with ${ store:KEY } syntax, set up .env files, configure secret store precedence, or understand how the `secrets:` section works. Also use when the user asks how to pass database passwords or API keys securely to Spice datasets or models.
---

# Spice Secret Stores

Secret stores manage sensitive data like API keys, passwords, and tokens. The `env` store is loaded by default.

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
| AWS Secrets Manager | `aws_secrets_manager` | AWS Secrets Manager |
| Keyring | `keyring` | OS keyring (macOS Keychain, Linux, Windows) |

## Default: Environment Variables

Loaded automatically. Reads from environment variables and any `.env.local` or `.env` files in the project directory.

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
  - from: aws_secrets_manager
    name: aws
    params:
      aws_region: us-east-1
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
- [Keyring Secret Store](https://spiceai.org/docs/components/secret-stores/keyring)
