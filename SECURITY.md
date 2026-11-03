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

## Disclosure

Fixes are coordinated with the reporter in a private GitHub Security Advisory. The advisory is published, with a CVE when one applies, once the fixed prerelease is on RubyGems, and the CHANGELOG entry links to it. Please keep the details private until then.

## How changes are reviewed

The project has one maintainer today, and no second human reviewer. To make up for part of that, every change to a security rule goes through an independent verification before it is merged: a separate AI agent writes its own attacks against the change before reading the author's tests, runs them on both graphql-ruby engines and an older graphql version, and compares each with `main`. Whatever it finds is fixed, documented as a limit, or tracked with its reproduction before the merge, and the attacks that matter stay in the test suite. The process is in [.github/VERIFICATION.md](.github/VERIFICATION.md).

This is not the same as a second human reviewer. If you can review security changes regularly, say so in an issue.

## What counts

In scope: a query, ID, cursor, operation id or rate-limit key that gets past a documented guarantee of a module, or a misconfiguration that silently lets everything through.

Out of scope: the limits each module page documents under "Guarantees and limits" (for example, that a running operation is never interrupted), and vulnerabilities in graphql-ruby, Pundit, CanCanCan or Redis themselves, which belong to those projects.
