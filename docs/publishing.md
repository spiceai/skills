# Publishing spiceai

The plugin identifier is `spiceai` in every client. Public runtime skills live in `skills/`.
Maintainer automation stays in the ignored `.private/skills/` directory and must never be
committed or included in an archive. Git history and old releases are not rewritten by packaging.

## Release automation

1. Update every manifest/catalog version and each skill's runtime compatibility section.
   The plugin version follows the supported Spice runtime release, currently `2.3.2`.
2. Run `make check test-distribution release-preview`. The preview is in `dist/preview/`;
   its catalog entries contain placeholder SHAs because local changes may not exist at the
   recorded base commit. Pull requests and `trunk` pushes run these same checks
   and retain the preview as an Actions artifact.
3. Merge the changes, then create and push a new `v<version>` tag at that clean commit.
   The **Release Plugin** workflow validates the tag, builds the release, and creates a **draft
   GitHub release** with all artifacts and marketplace instructions. Review and publish that draft.
   If you create a release in GitHub's UI, its `published` event also runs the workflow.
4. To retry an existing tag, dispatch **Release Plugin** with its exact tag. Locally, the equivalent
   build is `make release-assets TAG=v<version>` from a clean checkout at the tag. The workflow
   always checks out that tag rather than the latest default branch.

The workflow needs only the repository's built-in `GITHUB_TOKEN` with `contents: write` for
release assets and notes. Validation uses read-only permissions and no credentials for model APIs.
It does not create tags, move existing tags, open external PRs, or submit policy attestations.
Do not reuse a tag that points to earlier content: use a new release version or keep working in a
local preview until the next runtime-aligned release. Public marketplace versions must satisfy
each marketplace's update rules.

Every release attaches:

- `spiceai-plugin-<version>.zip`: OpenAI upload and portable client package.
- `spiceai-plugin-<version>.tar.gz`: the same files in tar format.
- `spiceai-plugin-<version>-SHA256SUMS.txt`: hashes of every other release asset.
- `spiceai-{claude,github,grok}-marketplace-<version>.json`: one catalog entry per destination,
  pinned to the release's full commit SHA.
- `spiceai-submission-<version>.md`: upload links, install commands, PR preparation, and review steps.
- `spiceai-release-<version>.json`: source identity, public skill list, assets, and OpenAI listing metadata.

Archives have normalized timestamps, ownership, and permissions for reproducible reruns.
The uploader checks local and public tag commits, archive contents, and all asset checksums before
writing to GitHub. Reruns replace the generated block of release notes while preserving human-written
notes, and retain an existing release's draft/published state. A failure to read a release other than
HTTP 404 stops the uploader rather than attempting to create another release.

## Marketplace handoff

| Destination | Repository distribution | Curated/public listing |
| --- | --- | --- |
| Claude | `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json` | Submit the public GitHub repository through the [Claude directory portal](https://claude.com/blog/build-plugins-for-claude), address review, then publish |
| OpenAI | `.agents/plugins/marketplace.json`, root `plugin.json`, and `.codex-plugin/plugin.json` | Upload the release ZIP at [OpenAI Plugins](https://platform.openai.com/plugins), complete identity/scan/review steps, then publish |
| GitHub Copilot | `.github/plugin/marketplace.json` and the portable root `plugin.json` | Contribute the generated entry to [github/copilot-plugins](https://github.com/github/copilot-plugins/blob/main/CONTRIBUTING.md), following its current contribution process |
| Grok | `.grok-plugin/marketplace.json` and `.grok-plugin/plugin.json` | Contribute the generated entry to [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace/blob/main/CONTRIBUTING.md), regenerate its component index, and pass upstream checks |

GitHub here means the **Copilot plugin marketplace**, not the GitHub Apps/Actions Marketplace.
The repository catalogs use local sources so an extracted package or a checkout at a tag installs
its own files. Curated catalog entries use immutable remote SHAs. No GitHub release or local
marketplace registration implies acceptance by another marketplace.

The generated submission guide includes the destination catalog paths and commands. Entries must
be added to the destination's `plugins` array, not replace its entire catalog. Update an existing
`spiceai` entry instead of adding duplicates. For GitHub, maintain its Claude compatibility catalog
as well. For Grok, regenerate `.grok-plugin/plugin-index.json` using the upstream generator and run
both the catalog validator and the index freshness check before opening the PR.

For OpenAI, retain `spiceai` for subsequent uploads. A draft using an older package name requires
a new draft. If privacy-policy assessment is incomplete, the current policy is
[Spice AI Privacy Policy](https://docs.spice.ai/legal/privacy); use the additional-review path
offered by the portal. Our validator checks packaging conventions and known installer regressions;
it does not reproduce or bypass marketplace safety scans.

## Network and credential disclosure for reviewers

The package contains instructions and two bundled helpers, with no hosted MCP server or install hooks.
Cloud management uses `https://api.spice.ai` with a user-provided personal/OAuth access token;
OAuth exchange uses `https://spice.ai/api/oauth/token`. Runtime SQL, search, and inference use
the user's existing local runtime or Cloud project endpoints and project API keys as appropriate.
Configured data connectors and model providers contact the endpoints the user selects and require
their own credentials. Credentials are not included in the package.

The cookbook helper reads or fetches `https://github.com/spiceai/cookbook` (including a requested
branch/PR); cookbook workflows can run recipe dependencies and examples after inspecting their
requirements. Those recipes are outside this plugin archive and must be considered during review.
Documentation links point to Spice AI and the relevant upstream providers. Runtime installation
and upgrades are user-managed prerequisites; `setup` and `cookbook` stop if the runtime is missing.

## Official references

Publishing routes checked on 2026-09-30:

- [Claude marketplace creation and validation](https://code.claude.com/docs/en/plugin-marketplaces)
- [Claude directory submission](https://claude.com/blog/build-plugins-for-claude)
- [OpenAI submission and publication](https://developers.openai.com/plugins/deploy/submission)
- [OpenAI submission errors and version/name requirements](https://developers.openai.com/plugins/deploy/submission-errors)
- [GitHub Copilot marketplace and source format](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference)
- [Grok catalog, SHA pinning, and generated index](https://github.com/xai-org/plugin-marketplace/blob/main/README.md)
