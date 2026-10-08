# Management MCP server

Detailed reference for the Spice.ai Cloud management MCP server. The `cloud` skill links here from its
Management MCP server section.

The management MCP server exposes the Management API as MCP tools, so an agent can create, deploy, and
inspect Cloud projects through tool calls. It is a different server from the MCP endpoint of a deployed
project:

| | Management MCP server | Project runtime MCP |
| --- | --- | --- |
| URL | `https://api.spice.ai/mcp` | `<project endpoint>/v1/mcp` |
| Does | Manages projects, deployments, secrets, API keys, monitors, and members | Queries the project's data: `sql`, `list_datasets`, `table_schema`, `search` |
| Credential | Management token in `Authorization: Bearer` | Project API key in `X-API-Key` |
| Skill | `cloud` | `sql`, `search`, `chat` |

Never send a project API key to `api.spice.ai`, and never give a management token to a client of the
project endpoint.

## Connect

The server uses Streamable HTTP. Authenticate in one of two ways:

- **A management token in a header** (agents, CI, scripts): a personal access token from
  [spice.ai/account/tokens](https://spice.ai/account/tokens), or an OAuth client-credentials access token
  (see Authentication in `SKILL.md`). Keep the token in an environment variable and reference it from
  the client configuration, so it never appears in a prompt or a committed file. For Claude Code
  (`.mcp.json`, which expands `${VAR}`):

  ```json
  {
    "mcpServers": {
      "spice-cloud": {
        "type": "http",
        "url": "https://api.spice.ai/mcp",
        "headers": { "Authorization": "Bearer ${SPICE_API_TOKEN}" }
      }
    }
  }
  ```

- **Browser sign-in (OAuth)**: the server advertises OAuth 2.0 authorization code with PKCE, with
  `https://spice.ai` as the authorization server. It has no dynamic client registration, so the MCP
  client needs the ID of an OAuth client the user creates in the portal (**Account → User OAuth**) with
  the client's redirect URI. The project's endpoints page has install commands for common agents with
  the client ID filled in.

A request without a valid token returns `401` with a `WWW-Authenticate` header that names
`/.well-known/oauth-protected-resource`.

### Scopes

Each tool needs the scope of the Management API route it calls; a write scope includes its read scope,
and `*` grants all. The deploy workflow below needs:

| Tools | Scope |
| --- | --- |
| `list_orgs`, `list_regions`, `list_projects`, `get_project`, `list_project_instances`, `get_project_instance_logs`, `list_project_api_keys` | `apps:read` |
| `create_project`, `update_project`, `connect_project_repository`, `pause_project`, `resume_project` | `apps:write` |
| `delete_project` | `apps:delete` |
| `create_project_secret`, `link_project_org_secret` | `secrets:write` |
| `get_project_deployment`, `list_project_deployments` | `deployments:read` |
| `create_project_deployment` | `deployments:write` |

Mutations also need a member role or higher in the organization; viewers are read-only.

### Organization

Tools take an `org` argument: an organization handle from `list_orgs` (sent as `X-Org-Name`).
Without it, a call acts in the organization the token was minted against, and a project in another
organization answers `404`. Pass `org` on every call when the user belongs to several organizations.
OAuth client-credentials tokens act only in their own organization.

## Discover tools

Read the tool list from the server instead of assuming it: `tools/list` returns every tool with its
JSON Schema. Tool names are `<verb>_<resource>` (`create_project`, `get_project_deployment`), and
arguments use the Management API field names (`projectId`, `deploymentId`, `instanceName` are path
parameters; the rest are body or query fields). The server's `initialize` result includes
instructions that name the deploy workflow. `resources/list` and `resources/templates/list` expose the
read operations as `spiceai://cloud/v1/...` URIs, and `prompts/list` has starter prompts.

A tool result carries the API response in `structuredContent`. A refused call returns `isError: true`
with `structuredContent` `{"status": <HTTP status>, "body": {"error": "...", "code": "..."}}`; act on
`code`. `get_project` and `update_project` leave out the project's API keys; only
`list_project_api_keys` and `regenerate_project_api_key` return them, so call those only when a key is
needed, and never repeat a key back to the user.

## Deploy a project from a GitHub repository

The repository must belong to the organization's GitHub account and be readable by the organization's
Spice Cloud GitHub App installation. Arguments below are examples; pass `org` on every call.

1. `list_orgs`; choose the org handle with the user.
2. `create_project` `{"org": "acme", "name": "sales-bi", "region": "us-east-1"}` returns the project
   `id` and its data-plane `endpoint`. `default_alerts` (default `true`) creates the default monitors;
   `false` skips them.
3. `connect_project_repository` (Oct 2026) `{"org": "acme", "projectId": 123, "repository": "acme/analytics",
   "root_directory": "sales-bi", "production_branch": "main"}`. `repository` is `name` or `owner/name`;
   `root_directory` is the directory that holds `spicepod.yaml` (omit it for the repository root);
   `production_branch` defaults to the repository's default branch. The result has `has_spicepod: true`
   when the directory holds a spicepod. Connecting sets the project description to the repository's,
   and connecting again replaces the repository, directory, and branch.
4. For each `${ secrets:NAME }` in the spicepod: `link_project_org_secret` `{"projectId": 123,
   "secretName": "NAME"}` for an organization secret, or `create_project_secret` `{"projectId": 123,
   "name": "NAME", "value": "..."}`. A value sent through a tool call passes through the conversation,
   so prefer an organization secret, and never put a secret value in the repository.
5. `create_project_deployment` `{"org": "acme", "projectId": 123}` reads `spicepod.yaml` from the head
   of the production branch when it is created; the result records `branch` and `commit_sha`.
6. `get_project_deployment` `{"projectId": 123, "deploymentId": 456}` until `status` is `succeeded` or
   `failed` (then read `error_code` and `error_message`). Wait about 10 seconds between calls.
7. `list_project_instances` (Oct 2026) returns instances newest first, each with `name`, `status`
   (`ready` when serving), and `started_at`.
8. `get_project_instance_logs` (Oct 2026) `{"projectId": 123, "instanceName": "<name>", "tail": 200}`
   returns `lines`, oldest first. Look for `All components are loaded. Spice runtime is ready!` and for
   each dataset's `registered` or error line. `tail` defaults to 100; above the plan's limit it fails with
   `403 plan_limit` and `max_tail`.
9. Prove the runtime serves data: query the project `endpoint` with its API key (see Using API Keys with
   Runtime in `SKILL.md`, and the `sql` skill). A `succeeded` deployment alone is not proof.

To change the spicepod of a connected project, change `spicepod.yaml` in the repository and create a
new deployment. `update_project` with a different `spicepod` fails with `409 github_connected`.
Disconnecting a repository is done in the portal.

To deploy without a repository, send the spicepod with `update_project` `{"projectId": 123,
"spicepod": "<YAML string or JSON object>"}` instead of step 3.

### connect_project_repository errors

| `code` | Fix |
| --- | --- |
| `invalid_repository` (400) | Use a repository in the organization's GitHub account |
| `invalid_root_directory` (400) | Use a path inside the repository, without `..` |
| `repository_not_found` (404) | Give the organization's Spice Cloud GitHub App access to the repository, or fix the name |
| `github_not_connected` (409) | Connect GitHub to the organization in the portal first |
| `root_directory_conflict` (409) | Another project already deploys this repository and directory |
| `branch_not_found` (422) | Name an existing `production_branch` |
| `spicepod_missing` (422) | The project has no spicepod configuration |
| `github_unavailable` (503) | GitHub did not answer; retry |

## Pause, resume, and delete

- `pause_project` tears the runtime down and keeps the project, secrets, keys, and monitors. While paused,
  `create_project_deployment` fails with `400 spicepod_paused` and `list_project_instances` with
  `409 project_paused`.
- `resume_project` returns `deployment_id`. For a connected project it deploys `spicepod.yaml` from the
  head of the production branch; if that read fails, the project stays paused and the result has the
  same error a deployment gets. Follow the deployment with `get_project_deployment` until it is
  `succeeded` or `failed`.
- `delete_project` deletes the project and its runtime (`status` `204`). Run it only after the user
  confirms.

## Instance log errors

| `code` | Meaning |
| --- | --- |
| `project_not_deployed` (409) | The project has no deployment yet |
| `project_paused` (409) | Resume the project first |
| `instance_not_found` (404) | Take the name from `list_project_instances` |
| `instance_offline` (409) | The instance is not running |
| `plan_limit` (403) | `tail` is above `max_tail` |
