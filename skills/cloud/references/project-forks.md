# Project forks

Detailed reference for Cloud project forks. The `cloud` skill links here from its Projects and Common Workflows sections.

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

## Fork error codes

| Issue | Solution |
| --- | --- |
| `400 fork_placement_required` | The source runs on a BYOC cluster, a self-hosted runtime, or a region or cluster that is gone; set `region` or `cluster_name` for the fork |
| `400 scheduler_state_location_*` | The source is distributed; set `scheduler_state_location` to an `s3://` URI outside the source's (`_required`, `_unsupported`, `_overlaps_source`). `_not_applicable` means the source is not distributed, so omit the field |
| `409 fork_name_unavailable` | Every default `<source>-fork-N` name is taken; set `name` |
| `422 fork_source_has_no_spicepod` / `fork_source_spicepod_invalid` | The source has no spicepod or an invalid one; fix the source's spicepod, then fork again |
| `422 fork_source_loads_repository_files` | The source's spicepod loads other files from its GitHub repository; fork the repository on GitHub, then fork the project in the portal, which deploys from the forked repository |
| `502 fork_source_repository_unreadable` | The source's spicepod could not be read from its GitHub repository; retry, or fix the repository or the GitHub App's access to it |

