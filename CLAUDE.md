# graphql-armory: working rules

Open-source extensions for graphql-ruby, one module at a time. Read `README.md` for the module list and `docs/<module>.md` for what each one does.

## Hard rules

- **Clean room.** Use only graphql-ruby's open-source code, its public guides, and the public docs of Pundit and CanCanCan. Never copy, derive from, or try to obtain GraphQL-Pro or GraphQL-Enterprise code. If something can only be known from Pro's code, say so and design our own solution.
- **Never modify the graphql-ruby clone** (`../graphql-ruby`). Read-only. Hook only through public extension points; no fork, no monkey patching where a public hook exists.
- **Commits:** conventional commits, English, no `Co-Authored-By` or AI attribution lines. The commit author email is the GitHub noreply address, never a personal one; do not put a personal email in any file.
- **Remote operations.** Pushing a branch and opening its PR is expected for every increment. Merging, force-pushing, deleting remote branches and publishing the gem (pushing a `v*` tag publishes it through `release.yml`) are the user's decisions: ask first.
- **Style: the [Doctrine of Useful Objects](https://eventide-project.org/user-guide/useful-objects.html#the-doctrine-of-useful-objects), hand-written** (no `evt-*` gems). Every module, not only the first one:
  - `new` is inert and useful at once: each dependency defaults to a null object (`Adapters::Null`, `Store::Null`) that refuses or does nothing. A misconfigured object never lets anything through.
  - `self.build(...)` validates the settings and wires the real dependencies; `use` and other entry points go through `build`.
  - One actuator, `call`: `self.call(...)` is `build(...).(...)` where it makes sense.
  - Each dependency has a `Substitute` in `lib/` (answers what it is told, records its calls, can be told to fail), used by the specs instead of hand-written fakes.
  - Telemetry instead of mocks: tests read what the object recorded (sinks or the context record), not call expectations.
  - Test data lives in `lib/` as `Controls::X.example`, so other projects can reuse it.
  - RSpec uses no mocks (`mock_with :nothing`; no `receive`, `instance_double` or `stub_const`).

## Workflow per increment

1. One branch off `main` (`feat/<name>`), one PR against `main`. Tests first (observe RED), then code, then docs (the module page in `docs/`, CHANGELOG, the Modules table in README).
2. Run the suite on both engines and an older graphql before opening the PR:
   ```
   docker compose run --rm test bash bin/test                                              # interpreter, graphql 2.6
   GRAPHQL_ARMORY_ENGINE=next GRAPHQL_VERSION="~> 2.6.0" docker compose run --rm test bash bin/test
   GRAPHQL_VERSION="~> 2.4.0" docker compose run --rm test bash bin/test
   ```
   Always go through `bin/test`: calling `bundle exec rspec` directly skips `bundle install` and fails on new gems. Ruby is not installed on the host.
3. **Independent verification before every merge, always.** See below. Record the verdict in the PR, and keep the full report in the maintainers' private notes, outside the repo (one report per verification: what was verified, how, verdict per requirement, blockers, advisories, what was done, what was not verified, key learnings).
4. Close with a Risk line (`Risk: item N (reason)` or `Risk: none`) and tell the user how to verify it themselves.

## Independent verification (mandatory before every merge)

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
- Probes are grouped in one spec file per run, each probe its own `it` so a failure does not mask the others, and that file runs once per configuration: interpreter and `next` on graphql 2.6, interpreter on 2.4. A result that differs between configurations is always reported, even when neither side is a blocker.
- Negative control: each probe is labelled "security" (the feature must change its outcome) or "preservation" (existing behaviour or a schema that must stay clean). A security probe that passes on the branch runs again on the `origin/main` copy: if it also passes there, it did not exercise the feature and is reported as "no coverage", not as "holds". A preservation probe is expected to pass on both.
- Finding a blocker does not end the verification: the whole probe list is run.
- Probe files: the verifier keeps each spec-shaped file in a third `mktemp -d` directory that it does not remove, and reports that path with a one-line index of its files. Docker mounts only the scratch copy, so it copies them there to run them. These are the inputs for `spec/regressions/`.
- Severity: a blocker is a realistic defect that reproduces, is not a documented limit, and this diff causes or leaves unfixed in what it claims to fix. Silently ignoring an option with success, or a refused user getting data, is always a blocker under that test. The same defect already on `origin/main` and outside what the PR claims to fix is a pre-existing finding: it does not stop the merge, and it must carry its reproduction and go to the backlog. A refusal for the wrong reason (right outcome, wrong rule or message) is an advisory.
- Output: at most about 600 words of analysis; code blocks, the probe-file index and the environment report do not count. Per requirement a verdict of holds / broken / no coverage; each blocker with a minimal reproduction and expected versus actual; advisories separately; a `## Not probed` block naming the surfaces not explored; and a closing `## Key Learnings` block of 1 to 5 numbered facts. Any finding with a security effect, advisories included, carries the exact code that reproduces it and its cause, or says the cause is unknown.

Before merging, the parent reproduces each finding with a security effect and knows its cause; a finding with an unknown cause is never merged past. A "holds" is read as "not broken by these probes", never as a guarantee. Whatever stays open, including the `## Not probed` surfaces that matter, is named to the user with its impact, as a risk and not as a detail.

Template:

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
keep the file in P and copy it into A and B to run it. Run it once per configuration: interpreter and
next on 2.6, interpreter on 2.4; report any difference between them. Every security probe that passes
in A runs again in B: if it also passes in B it is "no coverage", not "holds". Do not stop at the
first blocker.

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

Correction bounds: one batch fixes every reported blocker, then one recheck limited to those blockers, with no new break ideas. A new finding in a recheck is reported only: it is a blocker only if the correction caused it. Open blockers after that become one decision for the user. If the same blocker still fails after the correction, or the correction caused a new one, suggest to the user `/model fable` for the main session (it cannot change itself); the verifier stays on `opus`, so another model reviews the code.

Depth by change: security behavior gets the full verifier and that recheck. Docs get their claims checked against the code on `sonnet`, with no probe list.

**Audit-versus-runtime matrix.** `spec/security/audit_runtime_matrix_spec.rb` crosses where a rule lives, where its `policy:` lives and whether a bypass applies, on both engines. Its invariant: if a refused user gets the data, the audit must not say ok. A finding of a new shape adds a shape to it, not only a spec of its own.

**Backlog.** Pre-existing findings with a security effect are listed in the private notes with their reproduction, and each gets a shape in the matrix. Before a release, each open one is fixed, documented as a limit, or accepted by the user by name. None is published silently.

## Releases: CHANGELOG and tags

Both are public and written for someone upgrading the gem, in English. Never include anything from the private notes: no audited project, incident or verifier report.

**CHANGELOG.** Each increment adds its entry to `## Unreleased`. The release PR turns it into `## X.Y.Z (YYYY-MM-DD)`, in this order, leaving out empty sections:

1. A summary of two or three sentences: what this release is about and who should care, with links to the module pages in `docs/`.
2. `### Breaking`, `### Added`, `### Changed`, `### Fixed`, `### Security`, `### Docs`.
3. Each entry says what changed, the problem it solves, and how to use it (the option or command), plus its limit if it has one. A breaking entry says what to do to upgrade. Name the PR: `(#8)`.

**Tags.** Always annotated, never lightweight, and the message is never the merge commit's subject:

```
git tag -a vX.Y.Z -F <message file> <commit on main>
git push origin vX.Y.Z
```

The message file is written outside the repo and shown to the user with the request to publish, because pushing the tag publishes the gem and a pushed tag cannot be moved:

```
graphql-armory X.Y.Z: <what this release is about, in a few words>

<The CHANGELOG summary.>

Highlights
- <One line per thing that matters, with the option or class to use.>

Breaking changes and how to upgrade
- <What breaks and what to do, or "None".>

Docs
- <Links to the module pages.>

Verification
- Suite: <engines and graphql versions, examples, failures>.
- CI: <the full matrix result>. Independent verification: <verdict per PR, one line>.

Changelog: https://github.com/israelb/graphql-armory/blob/vX.Y.Z/CHANGELOG.md
Compare: https://github.com/israelb/graphql-armory/compare/v<previous>...vX.Y.Z
```

No AI attribution in the message. Check the result with `git tag -l --format='%(contents)' vX.Y.Z` before pushing.

## CI

The repository is public, so the full matrix runs by default: the repository variable `CI_FULL_MATRIX` is `true`. `spec-minimal` (Ruby 3.4, graphql 2.6, interpreter) runs only when it is `false` (`gh variable set CI_FULL_MATRIX --body false`), to save Actions minutes. The minimal job does not cover `Execution::Next`, so keep the variable `true` before any release. Docs-only changes skip CI.

Two rulesets protect the repository: `main` accepts changes only through a PR and cannot be deleted or force-pushed, and the `v*` tags cannot be deleted or moved (a tag push publishes the gem). The repository admin can bypass both, which is the only way to move a tag.

## Known traps

- `Execution::Next` is supported from graphql 2.6.2; the integration refuses it earlier.
- Policies and abilities must answer `true`, `false` or `nil`. Anything else raises `AdapterError`.
- A `loads:` or `find_by:` lookup always goes through the user's scope: a foreign id and a missing id must look identical.
- `to_definition` builds an ordinary context, not `NullContext`: a full-schema dump needs `context: { armory_full_schema: true }`.
