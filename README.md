# graphql-armory

Open-source extensions for [graphql-ruby](https://github.com/rmosolgo/graphql-ruby), built on its public extension points — no fork, no monkey patching.

The first module is **authorization**: Pundit and CanCanCan integration with deny-by-default coverage, a schema audit for CI, IDOR-safe lookups, scoped lists and connections, and visibility driven by the same policies.

> **Status: design phase.** Nothing is implemented or published yet. See [`docs/`](docs/README.md) for the research, the design proposal and its review.

## Roadmap

| Order | Module |
|---|---|
| 1 | Authorization (Pundit, CanCanCan) |
| 2 | Encrypted, versioned IDs and cursors |
| 3 | Persisted queries / operation whitelisting |
| 4 | Rate limiting |
| 5 | Stable (keyset) connections |
| 6 | Subscriptions over Pusher / Ably |
| 7 | Response caching |
| 8 | API versioning (changesets) |
| 9 | `@defer` / `@stream` |
| 10 | Dashboard |

Each module starts with its own research before design. The feasibility study ([`docs/feasibility.md`](docs/feasibility.md)) found all ten buildable on unmodified graphql-ruby.

## Related gems

- [graphql-armory-rust_parser](https://github.com/israelb/graphql-armory-rust_parser) — a GraphQL parser written in Rust, installable as graphql-ruby's default parser.

## Clean-room policy

This project is written independently. It uses only graphql-ruby's open-source code, its public guides, and the public documentation of Pundit and CanCanCan. It does not use, copy or derive from GraphQL-Pro or GraphQL-Enterprise code.

## License

MIT. See [LICENSE](LICENSE).
