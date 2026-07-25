---
name: improve-skills
description: Weekly maintenance audit that keeps every Spice skill in this repo current with what has actually shipped. Audits published Spice.ai OSS releases for user-visible changes, routes each verified change to the skills it affects, applies edits through skill-creator, runs the eval regression gate, and opens a PR. Use this skill whenever the user wants to refresh, audit, update, or check the staleness of the skills in this repo; mentions a new Spice release and wants the skills to catch up; asks what shipped upstream that the skills are missing; asks whether the skills still document removed or deprecated behavior; or runs the scheduled weekly/cron skill-maintenance job. Also use when the user says "audit the skills", "the skills are out of date", or "improve the skills". Every fact this skill publishes must be citable from a public source — internal repositories are used only to aim the search, never as content.
---

# Improve Skills

A recurring audit that closes the gap between what Spice actually does today and what the skills in this repo claim it does.

Skills rot silently. A skill that describes a parameter renamed three releases ago does not fail loudly — it confidently gives wrong advice, and the user trusts it because it came from a skill. This audit exists to catch that drift on a roughly weekly cadence.

## The disclosure model — read this before anything else

This repo is public. Every file, commit message, branch name, and PR body produced by this skill is a public artifact, permanently. Some audit sources are private. That tension is the central design constraint, and it is resolved by keeping two things strictly apart:

**An internal repository is a metal detector, not a shovel.** It tells you *where to dig*. You dig in public ground.

| Internal sources may tell you | Internal sources may never supply |
| --- | --- |
| Which surface area is churning | Field names, flags, defaults, code |
| That users hit friction somewhere | Error strings, log lines, stack traces |
| That a public doc looks incomplete | Numbers, benchmarks, limits, pricing |
| Which skill deserves attention this week | Names of people, companies, or deployments |
| That a public example is now wrong | Anything unreleased, planned, or embargoed |

Three gates enforce this. All three must pass before anything is pushed:

1. **Separation** — internal findings enter as questions ("does the acceleration skill cover retention correctly?"), never as answers.
2. **Public corroboration** — every atomic fact written into a skill carries a public URL that a stranger with no Spice access can open and verify. No citation, no edit. See `references/disclosure-policy.md` for what counts as a public source and how to handle borderline cases.
3. **Mechanical scrub** — `scripts/scrub.sh` scans the outgoing diff and PR body against a denylist and exits non-zero on a hit. It is a backstop for gates 1 and 2, not a replacement for them; a clean scrub on sloppy sourcing is still a leak.

If you are ever unsure whether something is publishable, it is not. The cost of omitting a true fact is one stale line for one more week. The cost of publishing an internal detail is unbounded and irreversible.

## Setup (first run only)

Run every command in this skill from the repo root; the scripts anchor
themselves there and expect repo-relative paths.

```bash
cfg=skills/improve-skills/config
cp $cfg/sources.example.yaml  $cfg/sources.local.yaml
cp $cfg/denylist.example.txt  $cfg/denylist.local.txt
```

Add the private repos to the `internal:` list in `sources.local.yaml`, and any customer or deployment names to `denylist.local.txt`. Both `*.local.*` files and the `.audit/` working directory are gitignored — that is deliberate, and it is why the internal source list never appears in a commit. Never move those entries into the committed `*.example.*` files.

If `sources.local.yaml` is absent the audit still runs, using public sources only. That is a degraded but completely valid mode — say so in the summary rather than failing.

## Workflow

### 1. Establish the window

```bash
bash skills/improve-skills/scripts/gather.sh
```

`gather.sh` resolves the window from `.audit/state.local.json` (the high-water mark from the last run), falling back to 7 days when there is no state. Pass `--since 2026-06-01` to override — useful for a first run, or after a long gap.

It writes public release bodies and internal signal into `.audit/<date>/` and prints a manifest to stdout. Everything under `.audit/` is gitignored. Read the internal signal files, then treat them as radioactive: nothing in them gets copied forward verbatim.

Check `complete` in the manifest before trusting the window. A source can fail to collect — GitHub's API returns transient errors, and requesting changed paths (`--with-paths`) is expensive enough to fail outright on busy repositories. Any entry in `incomplete` means coverage is unknown, not empty. Say so in the summary, and do not advance the state high-water mark in step 9, or the un-collected window is skipped forever.

### 2. Extract shipped changes from public sources

"Shipped" means a user running a released Spice build can use it today. Concretely, a change qualifies if it appears in a **published, non-prerelease** GitHub release of `spiceai/spiceai`, or is merged to trunk **and** documented in `spiceai/docs`.

It does not qualify if it is only in an open PR, only in an `-rc` release, only on trunk with no docs, or behind an undocumented flag. Merged-but-unreleased work is the most tempting category to include and the most likely to change shape before users see it — leave it for a future week.

**Two traps make unreleased work look shipped.** Both are easy to walk into because the source genuinely is public:

- `spiceai/docs` is Docusaurus-versioned. `website/docs/**` is the *next*, unreleased version; `website/versioned_docs/version-<X.Y>.x/**` is what users running the current release actually see. Corroborate against the versioned directory matching the latest published release, never against `website/docs/**`. A status table that says Beta in `version-2.1.x` and Stable in `website/docs` means the promotion has not shipped.
- Trunk artifacts — `.schema/spicepod.schema.json`, README status tables, Rust source — describe trunk, not the release. They are excellent for confirming the *spelling* of something you already know shipped, and misleading as evidence that it shipped at all. The schema is a bulk-regenerated snapshot of trunk, not a per-release artifact: it was byte-identical across v2.1.0 and v2.1.1, so diffing it dates nothing.

Whenever you read a repo file as evidence, pin it to the release tag rather than the default branch:

```bash
gh api "repos/spiceai/spiceai/contents/<path>?ref=<tag>" --jq '.content' | base64 -d
```

Then confirm the feature is *absent* at the previous release tag. A file that differs between two published tags is evidence of shipping; a file that differs from trunk is only evidence that trunk moved.

Being public is not the same as being released. Gate 2 asks whether a stranger can verify the fact; this step asks whether a user can *use* it today. A fact must clear both.

Where the release notes label something *experimental* or *preview*, carry that label into the skill verbatim. Users making architecture decisions need to know what is load-bearing.

From each release body, pull the user-visible surface: new or renamed parameters, changed defaults, new connectors, accelerators, SQL functions, API endpoints, CLI flags, and — most importantly — deprecations and removals.

### 3. Weight deprecations above additions

Models drift toward adding. Resist it. Ranked by how much they help a user:

1. **Removed or renamed** — the skill now teaches something that fails. Highest value; fix first.
2. **Changed default or changed recommendation** — silently wrong guidance.
3. **New capability the skill should route to** — genuinely useful.
4. **New capability nobody asked about** — usually not worth the lines.

Search the skills for what shipped *away*, not only what shipped. `grep -rn "<removed_param>" skills/` across the whole repo is the fastest way to find the blast radius of a rename.

Then sweep for link rot, which is the same problem seen from the other side:

```bash
bash skills/improve-skills/scripts/linkcheck.sh
```

Docs get reorganized between releases, so a page that resolved last month can 404 today. Treat a 404 as a lead rather than a typo: find where the page moved, and check whether it moved because the feature was renamed or removed. This runs in seconds and is the most useful thing available in a week where nothing shipped.

### 4. Guard the line budget

Skills are capped at roughly 500 lines because everything in a triggered skill occupies context. A weekly additive process compounds: fifty lines a week is an unusable skill by year end.

Treat each skill's length as a budget, not a limit. Adding a section is a reason to look for a stale one to cut. Aim for a roughly neutral net line count per skill per week; when a skill grows meaningfully, either prune or move reference material into a `references/` file. Report the per-skill line delta in the PR body so the trend stays visible.

### 5. Route each change to its skill

Skills get added and their scopes shift, so do not rely on a hardcoded table. Read the current frontmatter and route against it:

```bash
for f in skills/*/SKILL.md; do
  awk '/^name:/{n=$2} /^description:/{sub(/^description: /,""); print n": "$0; exit}' "$f"
done
```

Descriptions in this repo already state their boundaries and cross-references ("for engine selection see spice-accelerators"), so they are a reliable routing key. A change often lands in two skills — the conceptual one and the reference one. Put the explanation where the concept lives and the syntax where the reference lives; do not duplicate both in both.

Exclude `improve-skills` itself from the audit targets — it documents this process, not Spice.

If a shipped surface has no plausible home in any existing skill, that is a signal a new skill is warranted. Do not quietly create one: draft it, and give it its own clearly-marked section in the PR body so a human decides.

### 6. Apply edits through skill-creator

For each skill with confirmed changes, invoke `/skill-creator:skill-creator` with a concrete brief rather than a vague request — the quality of the edit tracks the specificity of the brief:

```
Update skills/<name>/SKILL.md.

Changes to apply (each with its public source):
- <change>  →  <public URL>
- <change>  →  <public URL>

Remove (no longer valid):
- <stale content>  →  <public URL showing removal>

Constraints: keep under 500 lines, match the existing house style
(YAML examples, comparison tables, cross-references to sibling skills),
aim for a neutral net line delta. See CLAUDE.md for repo conventions.
```

If the skill-creator plugin is not installed, apply the edits directly against
the same brief and house style rather than skipping the run — skill-creator
improves the edit, but the audit's value is in the sourcing, not the tooling.

Skill-creator's full loop includes a browser-based human review step. In an unattended weekly run there is nobody to review, so use skill-creator for the authoring discipline and stop before the interactive eval viewer — step 7 is the substitute gate. When a human *is* driving the session and a skill changed substantially, offer to hand off to the complete skill-creator loop instead; that is strictly better than the automated gate when someone is available to look.

### 7. Run the regression gate

```bash
make eval SKILL=<name>
```

The repo's existing eval harness is the automated quality bar. Every touched skill must pass before the PR opens. A regression means the edit broke something the skill previously did well — fix the edit, do not weaken the eval to make it pass.

If a shipped change genuinely invalidates an eval assertion (the old assertion tested behavior that no longer exists), update the assertion and call that out explicitly in the PR body — it is a meaningful change to the quality bar and reviewers must see it.

Gate only the skills you touched. A bare `make eval` runs every skill that has an `evals/evals.json`, including this one, whose own evals perform full audits and are far too heavy for a weekly run.

### 8. Scrub, then open the PR

```bash
bash skills/improve-skills/scripts/scrub.sh --base trunk --body .audit/pr-body.md
```

It scans committed, staged, unstaged, and untracked additions, so it is safe to
run before committing as well as after.

The scrub inspects added lines only, so pre-existing content does not generate noise. On a non-zero exit, **do not** push. Read each finding, remove the offending content at its root — a fact that trips the scrub usually failed gate 1 or 2 upstream, and deleting the sentence without asking how it got there means it recurs next week.

Then, on a dated branch (never on trunk, never force-push):

```bash
git switch -c skills/audit-$(date -u +%Y-%m-%d)
git add skills/
git commit -m "chore(skills): weekly audit $(date -u +%Y-%m-%d)" \
           -m "Updated: <skill list>. Sources: <public release tags>."
git push -u origin HEAD
gh pr create --base trunk --title "..." --body-file .audit/pr-body.md
```

### 9. Write the local report

Findings that could not be publicly cited get dropped from the PR and recorded in `.audit/<date>/report.md` (gitignored) under a **Needs public documentation** heading, described in whatever detail is useful locally. This is the pressure valve that makes gate 2 easy to obey: a real gap is not lost, it just becomes a docs task instead of a skill edit. Point the user at this file at the end of the run.

Finally, advance the high-water mark so next week's window starts here — but only if the manifest reported `complete: true`:

```bash
jq -n --arg t "<until from the manifest>" '{last_audit_utc: $t}' > .audit/state.local.json
```

## PR body template

The PR body is a public asset and gets scrubbed like any other. Cite public URLs; describe motivation in terms of what shipped, never in terms of who asked.

```markdown
## Weekly skill audit — <YYYY-MM-DD>

Window: <start> → <end>
Sources: spiceai/spiceai releases <tags>

### Updated
- **<skill>** (+N/-M lines) — <what changed and why> ([source](<public URL>))

### Removed as stale
- **<skill>** — <what was removed> ([source](<public URL>))

### Evals
`make eval SKILL=<name>` passing for all touched skills.
<Note any assertion changes and why.>

### Proposed new skills
<Only if step 5 found an unhomed surface. Otherwise omit.>
```

## Running it weekly

Wire it with `/schedule` or cron. Weekly is the right cadence: Spice releases roughly monthly, so most weeks find little, and that is a healthy outcome — a run that reports "two doc-link fixes, nothing else shipped" is working correctly. Resist manufacturing changes to justify the run.

When there is nothing worth changing, say so and open no PR.

## When to stop and ask

Escalate rather than guessing when:

- A change looks shipped in the release notes but the docs contradict it — the discrepancy itself is worth reporting.
- A rename has wide blast radius across many skills; a human should confirm the migration story before it is codified.
- The scrub keeps flagging the same area, which usually means the underlying fact should not be published at all.
- An eval regression is not obviously the edit's fault.

## Reference

- `references/disclosure-policy.md` — what counts as a public source, the full denylist rationale, and worked examples of borderline publish/don't-publish calls. Read it whenever a fact feels close to the line.
