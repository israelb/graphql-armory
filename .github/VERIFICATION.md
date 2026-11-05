# Independent verification (mandatory before every merge)

The verifier is a separate agent, not a script or a test. Use the `general-purpose` agent type: the `review-risk` type has no read or shell tools and verifies nothing. Brief it with the template below, filling the `<...>` parts. Its probe files are kept (see "Probe files"), so every probe that found a defect, and every useful one that passed, is kept as a regression test in `spec/regressions/` (or `spec/security/` when it is a clear new spec) before merging; a probe left out because it fails is listed in the private notes, never dropped silently. The parent removes the probe directory once they are converted.

Rules for the verifier's brief:

- Branch, PR number and the code diff to read (`git diff origin/main <branch> -- lib docs`). The spec files and the PR description come later (see "Anti-anchoring").
- Threat model, explicit: who the attacker is (query author, schema author, operator, other), what they control, and what is trusted. It also sets the depth: a schema author making a mistake is in scope, one evading the audit on purpose usually is not.
- Read-only on the repo and on the graphql-ruby clone. Probes only in scratch copies made with `mktemp -d` under the system temp dir (one from `git archive` of the branch's SHA, one from `git archive origin/main`), never in the workspace or `C:\tmp`. It runs `git status --porcelain` in the repo and in the graphql-ruby clone at the start and at the end, and reports any difference between the two (the parent may have uncommitted work, so a non-empty output alone means nothing).
- Never run `docker compose down -v`: the bundle volumes are shared with the workspace by name. Before removing a scratch copy, run `docker compose down --rmi local` inside it: compose creates a separate project named after the folder, and deleting the folder leaves its containers, networks and image behind. `--rmi local` removes only images with no tag of their own, so the `redis` image stays. Confirm no containers of that project remain, then remove the exact scratch directories and report that they are gone.
- Run specs only through `docker compose run --rm test bash bin/test <spec>`, with `GRAPHQL_ARMORY_ENGINE=interpreter|next` and `GRAPHQL_VERSION="~> 2.6.0"`, always `cd` explicitly into the scratch copy.
- Sanity check before any probe: take the SHA with `git rev-parse <branch>` in the repo, because an archive has no `.git`, and archive that exact SHA; the existing specs for the feature pass there under both engines; report the graphql-ruby version from `GraphQL::VERSION` inside the container, because `Gemfile.lock` is ignored by git and generated per copy. A failing sanity check stops the verification and is reported as such, not as a finding about the feature.
- Anti-anchoring: the verifier writes its full list of probes before reading the existing spec files or the PR description, then reads the specs only to drop duplicates. It reports the list as written plus what it dropped.
- What the feature must guarantee, plus the documented limits that are out of scope.
- A list of concrete ideas for breaking it, never "check it works". Always include these, where they apply:
  - Run it, do not only read the verdict: a probe of a check or an audit compares what it says with what the query really returns to a refused user.
  - Find out who really answers: read `method(name).owner` on the real class, because include order and graphql-ruby's own methods (not only the app's) can win over the plugin's. Try the shapes graphql-ruby generates, such as its install template.
  - Attack every exemption and filter in the diff: try to hide a real bypass behind each one.
- Probes are grouped in one spec file per run, each probe its own `it` so a failure does not mask the others, and that file runs once per configuration: interpreter and `next` on graphql 2.6, interpreter on 2.4. A result that differs between configurations is always reported, even when neither side is a blocker. A change with no security behavior runs its probes on the interpreter with graphql 2.6 only: CI covers the other configurations.
- Negative control: each probe is labelled "security" (the feature must change its outcome) or "preservation" (existing behaviour or a schema that must stay clean). A security probe that passes on the branch runs again on the `origin/main` copy, on the interpreter with graphql 2.6 only: if it also passes there, it did not exercise the feature and is reported as "no coverage", not as "holds". A preservation probe is expected to pass on both, and is not run on `origin/main`. A change with no security behavior needs no `origin/main` copy.
- Finding a blocker does not end the verification: the whole probe list is run.
- Probe files: the verifier keeps each spec-shaped file in a third `mktemp -d` directory that it does not remove, and reports that path with a one-line index of its files. Docker mounts only the scratch copy, so it copies them there to run them. These are the inputs for `spec/regressions/`.
- Severity: a blocker is a realistic defect that reproduces, is not a documented limit, and this diff causes or leaves unfixed in what it claims to fix. Silently ignoring an option with success, or a refused user getting data, is always a blocker under that test. The same defect already on `origin/main` and outside what the PR claims to fix is a pre-existing finding: it does not stop the merge, and it must carry its reproduction and go to the backlog. A refusal for the wrong reason (right outcome, wrong rule or message) is an advisory.
- Output: at most about 600 words of analysis; code blocks, the probe-file index and the environment report do not count. Per requirement a verdict of holds / broken / no coverage; each blocker with a minimal reproduction and expected versus actual; advisories separately; a `## Not probed` block naming the surfaces not explored; and a closing `## Key Learnings` block of 1 to 5 numbered facts. Any finding with a security effect, advisories included, carries the exact code that reproduces it and its cause, or says the cause is unknown.

Before merging, the parent reproduces each finding with a security effect and knows its cause; a finding with an unknown cause is never merged past. A "holds" is read as "not broken by these probes", never as a guarantee. Whatever stays open, including the `## Not probed` surfaces that matter, is named to the user with its impact, as a risk and not as a detail.

Template, in its security-behavior form. For code with no security behavior, leave out B everywhere (setup, negative controls, cleanup) and run the probes and the sanity check on the interpreter with 2.6 only.

```
Independently verify <feature> of the gem at <repo path> (branch <branch>, PR #<n>;
read `git diff origin/main <branch> -- lib docs`). Do NOT edit the repo or the graphql-ruby clone.
Run `git status --porcelain` in both now and at the end, and report any difference.

Setup: make three `mktemp -d` dirs under the system temp dir: A = `git archive` of the SHA from
`git rev-parse <branch>`, B = `git archive origin/main`, P = where you keep your probe files (kept,
not removed). Run specs only with `docker compose run --rm test bash bin/test <spec>` (env
GRAPHQL_ARMORY_ENGINE=interpreter|next, GRAPHQL_VERSION="~> 2.6.0" or "~> 2.4.0"); always cd into A
or B first. Never run `docker compose down -v`.

Sanity check first, in A: existing specs <spec files> pass under both engines; report
`GraphQL::VERSION` from inside the container (Gemfile.lock is ignored by git). If this fails, stop
and say so.

Before reading <spec files> or the PR description, write your full probe list from the code diff,
the module page in `docs/` and design-proposal section <n>. Then read the specs only to drop
duplicates; report the list and what you dropped.

Threat model: <attacker, what they control, what is trusted>.
Feature: <what it does>.
Security requirement: <what must hold>. Out of scope (documented limits): <limits>.

Try to BREAK it: <numbered ideas>.
Also: compare what it says with what really runs for a refused user; read `method(name).owner` on
the real class (include order, graphql-ruby's own methods, its install template); attack every
exemption and filter in the diff.

Group the probes in one spec file, each probe its own `it`, label each "security" or "preservation",
keep the file in P and copy it into A and B to run it. Run it in A once per configuration:
interpreter and next on 2.6, interpreter on 2.4; report any difference between them. Every security
probe that passes in A runs again in B, on the interpreter with 2.6 only: if it also passes in B it is
"no coverage", not "holds". Do not stop at the first blocker.

Blocker = a realistic defect that reproduces, is not a documented limit, and this diff causes or
leaves unfixed in what it claims to fix; an option silently ignored with success, or a refused user
getting data, is always a blocker under that test. The same defect already in B and outside what the
PR claims to fix is a pre-existing finding: report it with its reproduction, it does not stop the
merge. Refusing for the wrong reason is an advisory.

Cleanup: `docker compose down --rmi local` (no -v) inside A and B, confirm their containers are
gone, remove A and B and confirm, keep P.

Report (~600 words of analysis; code, probe index and environment report excluded): verdict per
requirement (holds / broken / no coverage), blockers with minimal reproduction and expected vs
actual, advisories apart, `## Not probed`, path of P with a one-line index of its files, and a
`## Key Learnings` block of 1 to 5 facts. Any finding with a security effect carries the exact
code that reproduces it and its cause, or says the cause is unknown.
```

**Design review before code, once per feature.** The whole feature is designed first, split into independent units. Before any unit writes its first RED spec, a read-only agent independent of the one that designed it (`general-purpose`, `opus`, no Docker, no probes) gets the whole design and the current code and answers one question: how would you break it? It names each gap with the code path that causes it. The design is fixed before any code. This is where the hole of a design is found cheaply; the verifier below is for what survives it. Units are not reviewed one by one.

**One verification per feature, at the end.** The units are built in parallel and merged into one integration branch with one PR; the verifier runs once, over that PR, after the full suite. Its brief carries the whole task log (every spec, and each unit's departures from the design) and the design, and asks it to attack the design decisions as well as the code. The cap below applies to that one PR.

**Hard cap: one full verification and one recheck per PR.** Correction bounds: one batch fixes every reported blocker, then one recheck limited to those blockers, with no new break ideas. The recheck is a new agent only when the correction changed the design; when it only closed the reported gaps, the parent reruns only the probes of those blockers, only on the configuration where they failed, and then the full suite once. No other probe and no new agent. A new finding in a recheck is reported only: it is a blocker only if the correction caused it. Whatever stays open after the recheck becomes one decision for the user and issues with a reproduction that was run; never a third round. If the same blocker still fails after the correction, or the correction caused a new one, suggest to the user `/model fable` for the main session (it cannot change itself); the verifier keeps its tier's model, so another model reviews the code.

Depth by change, so the verifier costs what the risk is worth:

| Change | Verifier | Probes |
|---|---|---|
| Security behavior (a check, a scope, a lookup, visibility, the audit's verdict) | design review, then `opus` | three configurations in A; security probes in B on the interpreter with graphql 2.6 |
| Code with no security behavior (performance, refactor, a report's text or location) | `sonnet` | interpreter with graphql 2.6, A only; no B |
| Docs | `sonnet`, claims checked against the code | none |

When unsure whether a change has security behavior, it has.

**Audit-versus-runtime matrix.** `spec/security/audit_runtime_matrix_spec.rb` crosses where a rule lives, where its `policy:` lives and whether a bypass applies, on both engines. Its invariant: if a refused user gets the data, the audit must not say ok. A finding of a new shape adds a shape to it, not only a spec of its own.

**Backlog.** Pre-existing findings with a security effect are listed in the private notes with their reproduction, and each gets a shape in the matrix. Before a release, each open one is fixed, documented as a limit, or accepted by the user by name. None is published silently.
