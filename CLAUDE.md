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

The verifier is a separate agent, not a script or a test. Use the `general-purpose` agent type: the `review-risk` type has no read or shell tools and verifies nothing. Brief it with the template below, filling the `<...>` parts. Its throwaway probes are lost, so every probe that found a defect, and every useful one that passed, is converted into a regression test in `spec/security/` before merging.

Rules for the verifier's brief:

- Branch, PR number and the diff to read (`git diff origin/main <branch>`).
- Read-only on the repo and on the graphql-ruby clone. Probes only in a scratch copy made with `mktemp -d` under the system temp dir (`git archive <branch>` into it), never in the workspace or `C:\tmp`. It removes that exact directory at the end and reports whether it is gone.
- Never run `docker compose down -v`: the bundle volumes are shared with the workspace by name.
- Run specs only through `docker compose run --rm test bash bin/test <spec>`, with `GRAPHQL_ARMORY_ENGINE=interpreter|next` and `GRAPHQL_VERSION="~> 2.6.0"`, always `cd` explicitly into the scratch copy.
- What the feature must guarantee, in the user's security terms, plus the documented limits that are out of scope.
- A list of concrete ideas for breaking it, never "check it works". Always include these, where they apply:
  - Run it, do not only read the verdict: a probe of a check or an audit compares what it says with what the query really returns to a refused user.
  - Find out who really answers: read `method(name).owner` on the real class, because include order and graphql-ruby's own methods (not only the app's) can win over the plugin's. Try the shapes graphql-ruby generates, such as its install template.
  - Attack every exemption and filter in the diff: try to hide a real bypass behind each one.
- Severity: a blocker is a realistic defect that reproduces and is not a documented limit. Silently ignoring an option with success is always a blocker. So is a refused user getting data while a declared rule does not run, whatever part of the code causes it, even outside the diff.
- Output: at most about 600 words, a holds/broken verdict per requirement, each blocker with a minimal reproduction and expected versus actual, advisories separately, and a closing `## Key Learnings` block of 1 to 5 numbered facts. Any finding with a security effect, advisories included, carries the exact code that reproduces it and its cause, or says the cause is unknown.

Before merging, the parent reproduces each finding with a security effect and knows its cause; a finding with an unknown cause is never merged past. Whatever stays open is named to the user with its impact, as a risk and not as a detail.

Template:

```
Independently verify <feature> of the gem at <repo path> (branch <branch>, PR #<n>;
read `git diff origin/main <branch>`). Do NOT edit the repo or the graphql-ruby clone.
Probe only in a scratch copy from `mktemp -d` under the system temp dir; run specs with
`docker compose run --rm test bash bin/test <spec>` (env GRAPHQL_ARMORY_ENGINE=interpreter|next,
GRAPHQL_VERSION="~> 2.6.0"); always cd into the scratch copy; remove it at the end and say so.
Read first: <files>, <spec files>, the module page in `docs/`, design-proposal section <n>.
Feature: <what it does>.
Security requirement: <what must hold, in the user's words>.
Try to BREAK it with inputs the existing specs do not cover: <numbered ideas>.
Compare what it says with what really runs for a refused user; read `method(name).owner` on the
real class (include order, graphql-ruby's own methods, its install template); attack every
exemption and filter in the diff.
A blocker = a realistic defect that reproduces and is not a documented limit; an option
silently ignored with success is always a blocker, and so is a refused user getting data while a
declared rule does not run, even outside the diff.
Report at most ~600 words: verdict per requirement (holds/broken), blockers with a minimal
reproduction and expected vs actual, advisories apart, and a `## Key Learnings` block. Any finding
with a security effect carries the exact code that reproduces it and its cause, or says the cause
is unknown.
```

Correction bounds: one batch fixes every reported blocker, then one recheck limited to those blockers. A new finding does not earn another round; open blockers after that become one decision for the user.

## CI

The repository is public, so the full matrix runs by default: the repository variable `CI_FULL_MATRIX` is `true`. `spec-minimal` (Ruby 3.4, graphql 2.6, interpreter) runs only when it is `false` (`gh variable set CI_FULL_MATRIX --body false`), to save Actions minutes. The minimal job does not cover `Execution::Next`, so keep the variable `true` before any release. Docs-only changes skip CI.

Two rulesets protect the repository: `main` accepts changes only through a PR and cannot be deleted or force-pushed, and the `v*` tags cannot be deleted or moved (a tag push publishes the gem). The repository admin can bypass both, which is the only way to move a tag.

## Known traps

- `Execution::Next` is supported from graphql 2.6.2; the integration refuses it earlier.
- Policies and abilities must answer `true`, `false` or `nil`. Anything else raises `AdapterError`.
- A `loads:` or `find_by:` lookup always goes through the user's scope: a foreign id and a missing id must look identical.
- `to_definition` builds an ordinary context, not `NullContext`: a full-schema dump needs `context: { armory_full_schema: true }`.
