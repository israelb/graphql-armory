# graphql-armory: working rules

Open-source extensions for graphql-ruby (authorization first). Read `README.md` for what the gem does.

## Hard rules

- **Clean room.** Use only graphql-ruby's open-source code, its public guides, and the public docs of Pundit and CanCanCan. Never copy, derive from, or try to obtain GraphQL-Pro or GraphQL-Enterprise code. If something can only be known from Pro's code, say so and design our own solution.
- **Never modify the graphql-ruby clone** (`../graphql-ruby`). Read-only. Hook only through public extension points; no fork, no monkey patching where a public hook exists.
- **Commits:** conventional commits, English, no `Co-Authored-By` or AI attribution lines. The commit author email is the GitHub noreply address, never a personal one; do not put a personal email in any file.
- **Remote operations.** Pushing a branch and opening its PR is expected for every increment. Merging, force-pushing, deleting remote branches and publishing the gem (pushing a `v*` tag publishes it through `release.yml`) are the user's decisions: ask first.
- **Style.** Useful Objects: `new` is inert, `build` wires real dependencies, `Substitute` classes, `Controls::*.example`. RSpec uses no mocks (`mock_with :nothing`; no `receive`, `instance_double` or `stub_const`).

## Workflow per increment

1. One branch off `main` (`feat/<name>`), one PR against `main`. Tests first (observe RED), then code, then docs (README, CHANGELOG, roadmap table).
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
- A list of concrete ideas for breaking it, never "check it works".
- Severity: a blocker is a realistic defect that reproduces and is not a documented limit. Silently ignoring an option with success is always a blocker.
- Output: at most about 600 words, a holds/broken verdict per requirement, each blocker with a minimal reproduction and expected versus actual, advisories separately, and a closing `## Key Learnings` block of 1 to 5 numbered facts.

Template:

```
Independently verify <feature> of the gem at <repo path> (branch <branch>, PR #<n>;
read `git diff origin/main <branch>`). Do NOT edit the repo or the graphql-ruby clone.
Probe only in a scratch copy from `mktemp -d` under the system temp dir; run specs with
`docker compose run --rm test bash bin/test <spec>` (env GRAPHQL_ARMORY_ENGINE=interpreter|next,
GRAPHQL_VERSION="~> 2.6.0"); always cd into the scratch copy; remove it at the end and say so.
Read first: <files>, <spec files>, the README section, design-proposal section <n>.
Feature: <what it does>.
Security requirement: <what must hold, in the user's words>.
Try to BREAK it with inputs the existing specs do not cover: <numbered ideas>.
A blocker = a realistic defect that reproduces and is not a documented limit; an option
silently ignored with success is always a blocker.
Report at most ~600 words: verdict per requirement (holds/broken), blockers with a minimal
reproduction and expected vs actual, advisories apart, and a `## Key Learnings` block.
```

Correction bounds: one batch fixes every reported blocker, then one recheck limited to those blockers. A new finding does not earn another round; open blockers after that become one decision for the user.

## CI

`spec-minimal` (Ruby 3.4, graphql 2.6, interpreter) runs by default to save Actions minutes while the repository is private. The full matrix runs when the repository variable `CI_FULL_MATRIX` is `true` (`gh variable set CI_FULL_MATRIX --body true`). Run the full matrix before any release: the minimal job does not cover `Execution::Next`. Docs-only changes skip CI.

## Known traps

- `Execution::Next` is supported from graphql 2.6.2; the integration refuses it earlier.
- Policies and abilities must answer `true`, `false` or `nil`. Anything else raises `AdapterError`.
- A `loads:` or `find_by:` lookup always goes through the user's scope: a foreign id and a missing id must look identical.
- `to_definition` builds an ordinary context, not `NullContext`: a full-schema dump needs `context: { armory_full_schema: true }`.
