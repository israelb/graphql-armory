# Security policy

graphql-armory exists to enforce security rules (authorization, encrypted IDs, persisted queries, rate limits), so a way around one of them is a vulnerability, not just a bug.

## Supported versions

The gem is in early development and published as prereleases. Only the latest prerelease on RubyGems receives fixes; check the [CHANGELOG](CHANGELOG.md) for it.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability.

Report it privately with GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. If that option is not available to you, open an issue that says only that you need a private channel, with no details, and a maintainer will arrange one.

A useful report has:

- what the rule is meant to guarantee (for example, "a client without access must not read this field");
- the smallest schema, context and query that break it, and the graphql-ruby version and engine (interpreter or `Execution::Next`);
- what you expected and what happened.

This is a small project maintained in spare time: reports are read and answered on a best-effort basis, with no fixed response time. A confirmed vulnerability is fixed in a new prerelease and credited in the CHANGELOG unless you prefer not to be named.

## What counts

In scope: a query, ID, cursor, operation id or rate-limit key that gets past a documented guarantee of a module, or a misconfiguration that silently lets everything through.

Out of scope: the limits each module page documents under "Guarantees and limits" (for example, that a running operation is never interrupted), and vulnerabilities in graphql-ruby, Pundit, CanCanCan or Redis themselves, which belong to those projects.
