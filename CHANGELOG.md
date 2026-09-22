# Changelog

## Unreleased

- Add the `spice-cookbook` skill, which sets up and runs recipes from the [Spice.ai cookbook](https://github.com/spiceai/cookbook). It picks a recipe by name or goal, fetches the cookbook (or a pull request or branch), and checks the runtime version, Docker, secrets, tools, and ports with `scripts/cookbook.sh` before running the README steps. The script reports whether each secret is set without printing its value.
- Fix spice-setup and spicepod-config, which set bind addresses with `spice run -- --http ...`. That fails on every v2 CLI (`argument '--http' cannot be used multiple times`) because `spice run` already passes `--http`. Use `spice run --http-endpoint`, `--flight-endpoint`, and `--metrics-endpoint` instead.
- Fix spice-search and spice-text-to-sql `rrf()` examples: the score column has been `_fused_score` since v2.0.0, not `fused_score`.

## 2.3.1

- Align plugin metadata with Spice.ai OSS runtime `v2.3.1`.
- Audit all 14 Spice skills against the v2.3.x docs ([spiceai.org/docs](https://spiceai.org/docs)), the release notes, and [docs.spice.ai](https://docs.spice.ai). Remove or replace removed and deprecated configuration, including `evals`, ONNX models, `-models` image tags, `acceleration.ready_state`, `google_api_key`, and the `/v1/apps` routes (now `/v1/projects`). Fix examples that failed to load, such as worker `type`, MCP `mcp_endpoint`, `runtime.http`, and `time_column` inside `acceleration`.
- Make the skills version-aware. Each skill has a `## Version Compatibility` section with the target release line (Spice v2.3.x, checked against v2.3.1), how to check the runtime version, and a table that maps old configuration to its replacement. Features added after v2.0.0 carry the release that shipped them.
- Add `make check-versions` (`scripts/check_versions.sh`), which keeps the plugin manifests and each skill's target release line in agreement.
- Add version-awareness evals to spice-data-connector, spice-models, and spicepod-config.
- Publishing: create GitHub Release tag `v2.3.1`; [Release Plugin](https://github.com/spiceai/skills/actions/workflows/release.yml) uploads `skills-plugin-2.3.1.zip`.

## 2.3.0

- First GitHub-versioned release aligned to Spice.ai OSS runtime `v2.3.0`.
- Plugin metadata (`.claude-plugin/plugin.json`, `marketplace.json`) set to `2.3.0`.
- Publishing: create GitHub Release tag `v2.3.0`; [Release Plugin](https://github.com/spiceai/skills/actions/workflows/release.yml) uploads `skills-plugin-2.3.0.zip`.
