# Disclosure policy

Read this whenever a fact feels close to the line. The SKILL.md summarizes the
three gates; this file is the judgment behind them.

## Contents

- [Why this is strict](#why-this-is-strict)
- [What counts as a public source](#what-counts-as-a-public-source)
- [The reverse test](#the-reverse-test)
- [Signal versus content, worked](#signal-versus-content-worked)
- [Special cases](#special-cases)
- [Uncitable findings](#uncitable-findings)
- [Reading scrub findings](#reading-scrub-findings)

## Why this is strict

`spiceai/skills` is public. Commits, branch names, and PR bodies are permanent
and indexed; deleting a file later does not unpublish it. Meanwhile the audit
draws on repositories that are not public.

The asymmetry is what drives the policy. Omitting a true fact costs one stale
line for one more week — recoverable, cheap, invisible. Publishing an internal
detail is irreversible and can affect people who never agreed to the trade. When
those two costs are compared honestly, the answer is nearly always "leave it
out." That is not timidity; it is correct expected-value reasoning, and it is
why "when unsure, omit" is the default rather than a cop-out.

## What counts as a public source

A public source is one a stranger with no Spice account, no org membership, and
no support relationship can open right now. In rough order of authority:

1. **Published, non-prerelease releases of `spiceai/spiceai`** — the definitive
   statement of what shipped. Release notes carry YAML examples and doc links,
   which makes them the best single source for skill content.
2. **`spiceai/docs` and docs.spiceai.org** — the canonical reference surface and
   the right thing to cite for a parameter or endpoint.
3. **Public trunk source in `spiceai/spiceai`** — good for confirming a
   parameter name or default when docs lag. Use with care: trunk includes
   unreleased work, so pair it with a release that contains it.
4. **`spiceai/cookbook` and the public blog** — useful for verifying that an
   example still runs, weaker as a normative reference.

Not public sources, regardless of how widely known the content feels: private or
internal repositories, support tickets, Slack, design docs, dashboards, customer
calls, and anything an employee knows by virtue of being an employee.

A private repository being readable by many people does not make it public. The
test is whether a stranger can read it, not how many insiders can.

## The reverse test

Before writing a line into a skill, ask:

> If I lost access to every private repository right now, could I still write
> this line and cite it?

Yes → publish it with the citation. No → it does not go in the skill; it goes in
the local report.

This test is more reliable than scanning for forbidden words, because leaks are
usually not a stray internal hostname. They are a specific, confident, correct
detail that could only have come from inside — an exact default, a precise
limit, a behavior nobody has documented yet. The scrub cannot catch that. The
reverse test can.

## Signal versus content, worked

Internal repositories answer *where to look*. Public sources answer *what to
write*. These examples show where the line falls.

**A private repo has heavy churn in a connector's retry handling.**
May: open the public docs and the public skill for that connector and check
whether the documented retry parameters are covered accurately and completely.
May not: describe the bug, the failure mode, the fix, or the fact that the area
was churning at all.

**A private repo shows a new capability being built.**
May: nothing, this week. Unreleased work has no public source by definition, and
its shape frequently changes before release.
May not: pre-announce it, hint at it, or "prepare" a skill section for it.

**An internal benchmark shows one accelerator outperforming another.**
May: check whether the public release notes or docs make a performance claim,
and cite that claim if so.
May not: publish the internal number, or state a comparison stronger than the
public claim supports. If public docs say "faster scans", the skill says "faster
scans" — not a ratio the public has never seen.

**Support traffic suggests users repeatedly misconfigure a documented option.**
May: improve how the skill explains that option — better example, clearer
default, an explicit note about the common mistake. This is the highest-value
use of internal signal and exactly what it is for.
May not: write "users often get this wrong" attributed to internal observation,
name anyone, or reproduce a real configuration from a real deployment.

**A private repo renames something that also exists in the public product.**
May: verify the rename against public release notes or docs; if it is public,
update the skill and cite the public source.
May not: apply the rename on internal authority alone. Internal and public
naming diverge, and a rename applied a release early actively breaks users.

**A cloud-only capability is exposed through a documented public API.**
May: document the public API surface — endpoint, parameters, responses — citing
public API docs.
May not: describe how it is implemented, what runs behind it, or capacity,
architecture, or operational detail.

**A security fix hardens a default that a skill recommends changing.**
May: update the skill once the fix appears in a published release and the
release notes or an advisory describe it.
May not: change the guidance ahead of disclosure. Publishing "don't set X" before
the fix ships tells attackers exactly where to look while users are still
exposed.

## Special cases

**Prioritization is allowed to be internally informed.** Choosing to spend this
week on the acceleration skill because internal signal points there is the
intended use. The resulting artifact — a better public skill, justified by
public sources — reveals nothing. Do not become paralyzed about direction; be
strict about content and about how that content is justified in writing.

**The PR body follows the same rules as the skills.** Motivation is stated in
terms of what shipped, not who asked. Write "documents the shared replication
slot parameter added in v2.1.0" — never "several deployments hit the slot limit."
The first is a citation. The second is a disclosure.

**Version numbers are facts too.** Referring to a version that has not been
published discloses release timing. Cite only tags that exist publicly.

**Absence is information.** "The skill no longer recommends X" invites the
question of why. If the removal is publicly justified, cite it. If it is not,
either leave the content alone this week or remove it without editorializing.

**Third parties get the same protection.** A partner's or vendor's non-public
detail encountered through internal work is subject to identical rules.

## Uncitable findings

A real problem with no public source is not a failure of the audit — it is a
finding of a different kind, usually a documentation gap.

Record it in `.audit/<date>/report.md` (gitignored) under **Needs public
documentation**, with enough local detail to act on: which skill is affected,
what appears to be wrong or missing, and what would need to be published before
the skill can be fixed. Surface that list to the user at the end of the run.

Having this pressure valve is what makes the corroboration gate easy to obey.
Without it there is constant temptation to publish something almost-citable in
order to avoid losing the insight. With it, nothing is lost — the work simply
routes to docs first, then to the skill next week.

## Reading scrub findings

`scripts/scrub.sh` inspects added lines only. Treat each finding as a question
about sourcing, not as a string to delete.

- **Genuine leak** — remove the content and re-examine how it got in. It almost
  certainly entered as content from a signal-only source, which means gate 1
  failed and something else in the same batch is probably also tainted.
- **False positive** — a legitimate public fact that resembles a denylisted
  pattern. Rephrase if that is natural; if the pattern is genuinely too broad,
  narrow it in `config/denylist.example.txt` and explain the change in the PR.
  Do not add per-line bypasses; a gate with an override is a gate that gets
  overridden.
- **New public host** — append it to `config/url-allowlist.txt` in the same PR
  so reviewers see every external domain the skills point at.
- **Repeat offender** — the same area tripping the scrub week after week means
  the underlying fact should not be published at all. Stop working around it and
  raise it with a human.
