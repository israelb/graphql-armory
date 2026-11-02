# Releases: CHANGELOG and tags

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
