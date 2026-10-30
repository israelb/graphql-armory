<p align="center">
  <img src="assets/logo.jpeg" alt="graphql-armory" width="560">
</p>

# graphql-armory

Open-source extensions for [graphql-ruby](https://github.com/rmosolgo/graphql-ruby), built on its public extension points: no fork, no monkey patching. One gem, one module at a time; each module has its own page in [`docs/`](docs) with the problem it solves, how to use it, and its limits.

> **Status: early development.** Prereleases on RubyGems (`0.1.0.pre5`). The API may change before 1.0.

## Install

```ruby
gem "graphql-armory", "~> 0.1.0.pre5"  # a prerelease: `gem install graphql-armory --pre`
gem "pundit"      # or "cancancan", for the authorization module
```

Requires Ruby >= 3.1 and graphql >= 2.4.

## Modules

Status: ✅ released, 🚧 in progress, ⬜ not started. Update this table in the same PR that changes a module.

| Order | Module | Status | Docs | Current limits |
|---|---|---|---|---|
| 1 | Authorization (Pundit, CanCanCan) | ✅ | [docs/authorization.md](docs/authorization.md) | Released in 0.1.0.pre2 (prerelease). Pundit and CanCanCan (the audit checks less with CanCanCan). Global IDs in `loads:` decoded through `object_from_id`; `loads:` inside input objects scoped with `include Base`. `Execution::Next` needs graphql >= 2.6.2. |
| 2 | Encrypted, versioned IDs and cursors | ✅ | [docs/encrypted-ids.md](docs/encrypted-ids.md) | Released in 0.1.0.pre4 (prerelease). `Encoder` (AES-256-GCM), versioned chains and `Legacy`, `Encoder.default` (ENV or Rails), `use GraphQL::Armory::IDs`. Composite primary keys not supported. |
| 3 | Persisted queries / operation allowlist | ✅ | [docs/persisted-queries.md](docs/persisted-queries.md) | Released in 0.1.0.pre4 (prerelease). Allowlist from a build manifest (Apollo, Relay), `use GraphQL::Armory::PersistedQueries` with strict mode. A runtime store (database, sync endpoint) is planned for later. |
| 4 | Rate limiting | ✅ | [docs/rate-limiting.md](docs/rate-limiting.md) | Released in 0.1.0.pre5 (prerelease). Points per client (query complexity) and operations at the same time, `MemoryStore` and `RedisStore`, the budget in response extensions and headers. A processing-time layer is planned for later. |
| 5 | Stable (keyset) connections | ⬜ | | Research not started. |
| 6 | Subscriptions over Pusher / Ably | ⬜ | | Research not started. |
| 7 | Response caching | ⬜ | | Research not started. |
| 8 | API versioning (changesets) | ⬜ | | Research not started. |
| 9 | `@defer` / `@stream` | ⬜ | | Research not started. |
| 10 | Dashboard | ⬜ | | Research not started. |

Each module starts with its own research before design. A module is ✅ only when it is released and its page documents its limits.

Every module page follows the same outline: **The problem**, **The solution**, **How to use it**, reference sections, **Guarantees and limits**.

Across modules: [Telemetry](docs/telemetry.md) shows how to see what the gem allowed, refused and ran, in your logs and metrics, without recording anything a client chose.

## Development

Ruby is not required on the host:

```
docker compose run --rm test                                    # full suite, interpreter
GRAPHQL_ARMORY_ENGINE=next docker compose run --rm test         # full suite, Execution::Next
GRAPHQL_VERSION="~> 2.4.0" docker compose run --rm test         # another graphql version
```

### Releasing

Releases are published from GitHub Actions with RubyGems Trusted Publishing (`.github/workflows/release.yml`): no API key is stored and no OTP is asked. Bump `GraphQL::Armory::VERSION` and the CHANGELOG on `main`, then push the matching tag:

```
git tag v0.1.0.pre5 && git push origin v0.1.0.pre5
```

The workflow checks that the tag matches the version, runs the specs and pushes the gem. It only publishes a tag on a commit of `main`. The `release` environment can require a maintainer's approval first (on a public repository, or a private one on a paid GitHub plan).

## Related gems

- [graphql-armory-rust_parser](https://github.com/israelb/graphql-armory-rust_parser): a GraphQL parser written in Rust, installable as graphql-ruby's default parser.

## Clean-room policy

This project is written independently. It uses only graphql-ruby's open-source code, its public guides, and the public documentation of Pundit and CanCanCan. It does not use, copy or derive from GraphQL-Pro or GraphQL-Enterprise code.

## License

MIT. See [LICENSE](LICENSE).
