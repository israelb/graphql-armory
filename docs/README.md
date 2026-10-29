# graphql-armory — Documentation index

> Research and design record for **graphql-armory**, an original open-source (MIT) Ruby gem that brings GraphQL-Pro/Enterprise-style capabilities to **unmodified** open-source graphql-ruby, starting with Pundit/CanCanCan authorization.
> Built clean-room: only open-source graphql-ruby code, its public guides, and the Pundit/CanCanCan/Eventide docs. No Pro/Enterprise code.
> Reference version: graphql-ruby **v2.6.13** (commit `23a5d65`), [rmosolgo/graphql-ruby@23a5d65](https://github.com/rmosolgo/graphql-ruby/tree/23a5d6595ef9f6e14d89a05e97e260fc8c9c1962).

## Decision documents

| Document | What it is | Status |
|---|---|---|
| [design-proposal.md](design-proposal.md) | Phase 1 design of the authorization module (architecture, API, deny-by-default, IDOR, errors, visibility, performance, stages) | Revised after review; name approved |
| [design-review.md](design-review.md) | Independent review of the proposal: claim verification, findings by severity, API ergonomics, Useful Objects fit | Done; decisions applied to the proposal |
| [feasibility.md](feasibility.md) | Can each Pro/Enterprise capability be built on public hooks, or does it need a fork? Roadmap | Done: **no fork needed** |

## Research record (`research/`)

Full findings with `file:line` evidence, kept so the research does not have to be repeated.

| # | Document | Topic | Date |
|---|---|---|---|
| 01 | [01-graphql-ruby-authorization-hooks.md](research/01-graphql-ruby-authorization-hooks.md) | Every authorization/visibility hook: signature, call site, result handling, both engines, gotchas, CHANGELOG 2.0→2.6 | 2026-10-28 |
| 02 | [02-pro-capabilities-and-community-gems.md](research/02-pro-capabilities-and-community-gems.md) | Pro Pundit/CanCan observable capabilities, community gems, name availability, full Pro/Enterprise feature inventory | 2026-10-28/29 |
| 03 | [03-eventide-useful-objects.md](research/03-eventide-useful-objects.md) | Doctrine of Useful Objects, Eventide utility libraries, why no `evt-*` deps, RSpec compromise | 2026-10-28 |
| 04 | [04-security-path-verification.md](research/04-security-path-verification.md) | 13 security-relevant execution paths verified (Next scope bypass, existence oracle, lazy auth), Pundit/CanCanCan facts | 2026-10-28 |
| 05 | [05-feasibility-ids-operationstore-limits-connections.md](research/05-feasibility-ids-operationstore-limits-connections.md) | Encrypted IDs/cursors, stable connections, OperationStore, rate limiting | 2026-10-29 |
| 06 | [06-feasibility-objectcache-changesets-subscriptions.md](research/06-feasibility-objectcache-changesets-subscriptions.md) | ObjectCache, Changesets, Pusher/Ably subscriptions | 2026-10-29 |
| 07 | [07-feasibility-defer-stream.md](research/07-feasibility-defer-stream.md) | `@defer` / `@stream` on both engines, degraded design, upstream hooks | 2026-10-29 |

## Decisions log

| Date | Decision |
|---|---|
| 2026-10-28 | Clean-room rules; hook only into public graphql-ruby extension points; never modify the clone |
| 2026-10-28 | Useful Objects pattern written by hand; no `evt-*` runtime dependencies; RSpec without `receive`/`instance_double` |
| 2026-10-28 | Gem name **graphql-armory** (`GraphQL::Armory`), MIT; one gem with opt-in modules; authorization first |
| 2026-10-28 | Neutral adapter contract: `actor`, `authorized?`, `scope`, `check` (fits Pundit and CanCanCan) |
| 2026-10-28 | `default_action` counts as coverage when the policy exists; bypass is `authorize :none, reason:` |
| 2026-10-28 | `Execution::Next` is first-class: the suite runs on both engines |
| 2026-10-28 | CanCanCan block-only rules fail with `MissingScopeError`; explicit `scope: :in_memory` opt-in |
| 2026-10-28 | Ruby >= 3.1; Pundit policy lookup from the model class via `Pundit::PolicyFinder` |
| 2026-10-29 | **No fork**: all ten capabilities are buildable on public hooks (two with semi-private dependencies) |
| 2026-10-29 | Naming family: `graphql-armory` is the brand; components hang with a dash (RubyGems: dashes = extensions, underscores = multi-word) |
| 2026-10-29 | The author's Rust GraphQL parser ships as a separate gem **`graphql-armory-rust_parser`** (`GraphQL::Armory::RustParser`), installed through the public `GraphQL.default_parser=` hook (`lib/graphql.rb:52-56`), same as `graphql-c_parser` (`graphql-c_parser/lib/graphql/c_parser.rb:157`). Separate because it is a native extension; `graphql-armory` may use it optionally |

## Gem family

| Gem | Constant | Repo (proposed) | Status |
|---|---|---|---|
| `graphql-armory` | `GraphQL::Armory` | `github.com/israelb/graphql-armory` | Design approved, not implemented |
| `graphql-armory-rust_parser` | `GraphQL::Armory::RustParser` | `github.com/israelb/graphql-armory-rust_parser` | Code imported (7 commits, 2026-10-28/29); still named `graphql-rust_parser` / `GraphQL::RustParser`, gemspec still carries graphql-ruby metadata, tests not standalone (see that repo's `TODO.md`). Author's benchmark: 1.25–1.31× faster than the C parser, ~30% fewer objects per parse (Apple M2 Pro, Ruby 3.3.6) |

Gem names free on RubyGems as of 2026-10-29; re-check before publishing. The GitHub account `graphql-armory` was also free (an option for moving both repos into an organization later).

## How to re-verify

Every claim cites a path in graphql-ruby at commit `23a5d65` (paths are relative to that repository). To re-check after a graphql-ruby upgrade, open the cited `file:line` in the new version; the most fragile ones are listed in `feasibility.md` §1–§4 and `design-review.md` (Critical/High).
