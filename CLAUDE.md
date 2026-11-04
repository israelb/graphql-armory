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
2. While fixing, run only the specs you touch on the interpreter with graphql 2.6. Run the full suite on both engines and an older graphql once, right before opening the PR (the three configurations can run in parallel only with a separate `BUNDLE_GEMFILE` and `BUNDLE_PATH` each, so they never share a lock):
   ```
   docker compose run --rm test bash bin/test                                              # interpreter, graphql 2.6
   GRAPHQL_ARMORY_ENGINE=next GRAPHQL_VERSION="~> 2.6.0" docker compose run --rm test bash bin/test
   GRAPHQL_VERSION="~> 2.4.0" docker compose run --rm test bash bin/test
   ```
   Always go through `bin/test`: calling `bundle exec rspec` directly skips `bundle install` and fails on new gems. Ruby is not installed on the host.
3. **Independent verification before every merge, always.** See below. Record the verdict in the PR, and keep the full report in the maintainers' private notes, outside the repo (one report per verification: what was verified, how, verdict per requirement, blockers, advisories, what was done, what was not verified, key learnings).
4. Close with a Risk line (`Risk: item N (reason)` or `Risk: none`) and tell the user how to verify it themselves.

## Independent verification (mandatory before every merge)

A separate `general-purpose` agent, on the model its risk tier names (below), briefed with the template in `.github/VERIFICATION.md`. Read that file before verifying, before a design review, and when a finding goes to the backlog. It also holds these, the ones most often needed:

- Security behavior gets a read-only design review before the first RED spec. Docs get their claims checked on `sonnet`, with no probe list.
- The verifier's model and probe configurations follow the change's risk: `opus` for security behavior, `sonnet` for everything else (table in `.github/VERIFICATION.md`).
- Hard cap: one full verification and one recheck per PR. One batch fixes every blocker. The recheck reruns only those blockers' probes, on the configuration where they failed, then the suite once. What stays open becomes one decision for the user and issues with a reproduction that was run.
- Matrix invariant (`spec/security/audit_runtime_matrix_spec.rb`): if a refused user gets the data, the audit must not say ok.

## Releases

Read `.github/RELEASING.md` before writing a CHANGELOG entry or a tag. Both are public and never include anything from the private notes.

## Guards

Rules with a script behind them. Enable the commit hook once per clone: `git config core.hooksPath .githooks`.

- `bin/check-commits` refuses an author that is not the noreply address, AI attribution and a subject that is not conventional, in the hook and on every PR (`.github/workflows/commits.yml`).

## CI

The repository is public, so the full matrix runs by default: the repository variable `CI_FULL_MATRIX` is `true`. `spec-minimal` (Ruby 3.4, graphql 2.6, interpreter) runs only when it is `false` (`gh variable set CI_FULL_MATRIX --body false`), to save Actions minutes. The minimal job does not cover `Execution::Next`, so keep the variable `true` before any release. Docs-only changes skip CI.

Two rulesets protect the repository: `main` accepts changes only through a PR and cannot be deleted or force-pushed, and the `v*` tags cannot be deleted or moved (a tag push publishes the gem). The repository admin can bypass both, which is the only way to move a tag.

## Known traps

- `Execution::Next` is supported from graphql 2.6.2; the integration refuses it earlier.
- Policies and abilities must answer `true`, `false` or `nil`. Anything else raises `AdapterError`.
- A `loads:` or `find_by:` lookup always goes through the user's scope: a foreign id and a missing id must look identical.
- `to_definition` builds an ordinary context, not `NullContext`: a full-schema dump needs `context: { armory_full_schema: true }`.
