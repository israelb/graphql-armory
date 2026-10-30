# Persisted queries

Your API runs the operations your clients were built with, and nothing else.

## The problem

A GraphQL endpoint accepts any query anyone writes. Authorization decides what each user may read, but the endpoint still:

- **Runs queries you never wrote.** Anyone with a token can send deep, wide or expensive queries, or explore the schema field by field to find something you forgot to protect.
- **Parses and validates every request.** A large query costs CPU before a single field resolves.
- **Sends the full query text on every request.** Mobile clients pay that in bandwidth.

## The solution

Your client's build step (Apollo's persisted query manifest generator, or Relay's `persistOutput`) writes every operation the app uses to a JSON file. The server loads that file and clients send the operation's id instead of its text:

- **An allowlist.** In strict mode the server refuses any query that is not in the file, before validating it, so a raw query cannot even probe field names.
- **Tamper-evident.** Every id must be the digest (SHA-256 by default) of its query. A manifest edited by hand to put another query behind an id is refused when the app boots.
- **Parsed once.** Each stored query is parsed at boot and handed to graphql-ruby as a document, so a request skips parsing.
- **Smaller requests.** The client sends a 64-character id and the variables.
- **Both engines.** It hooks only `Schema.query_class`, so it works on the interpreter and on `Execution::Next`.

## How to use it

Load the manifest and add the plugin:

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::PersistedQueries,
    store: GraphQL::Armory::PersistedQueries::Manifest.load(Rails.root.join("persisted-queries.json")),
    strict: true
end
```

Pass the operation id from the request in the context:

```ruby
class GraphqlController < ApplicationController
  def execute
    result = AppSchema.execute(
      params[:query],
      variables: params[:variables],
      operation_name: params[:operationName],
      context: {
        current_user: current_user,
        operation_id: GraphQL::Armory::PersistedQueries.operation_id(params),
        armory_allow_raw_query: current_user&.staff? || Rails.env.development?
      }
    )
    render json: result
  end
end
```

`PersistedQueries.operation_id(params)` reads the id where clients send it: `operationId`, `extensions.operationId`, or Apollo's `extensions.persistedQuery.sha256Hash` (`extensions` may be a JSON string, as in GET requests). It answers nil when there is no id.

What each request does:

| Request | Result |
|---|---|
| An id the manifest holds | Runs the stored operation with the request's variables and operation name. |
| An id plus the same query (Apollo's clients may send both) | Runs the stored operation. |
| An id plus a different query | Refused: `The operation id and the query do not match`. Neither runs. |
| An id the manifest does not hold | Refused: `Unknown operation id`. |
| A raw query, strict mode off | Runs as usual. Use this while clients migrate. |
| A raw query, strict mode on | Refused: `Only persisted operations are allowed: send an operation id`, unless the context holds `armory_allow_raw_query: true`. |

A refused request fails validation with that message as its only error, so nothing resolves, even when the app executes with `validate: false`.

### Relay

Relay's persisted output is a flat map of id to query text. Tell the manifest which digest Relay was configured with:

```ruby
GraphQL::Armory::PersistedQueries::Manifest.load("persisted-queries.json", digest: :md5)
```

`digest: false` accepts ids that are not digests (names such as `invoices-v1`). Then nothing proves an id belongs to its query: anyone who can edit the file can change what an id runs.

### Rolling it out

1. Generate the manifest in the client build and ship it with the server.
2. Add the plugin with `strict: false`. Clients that send ids get stored operations; everything else keeps working.
3. When every client in use sends ids, turn on `strict: true`.

Deploy the server with the new manifest before, or with, the clients that use its new operations: until then they get `Unknown operation id`. Keep old operations in the file while old app versions are still in use.

## Reference

`Manifest.new(data, digest: :sha256)`, `Manifest.load(path, digest: :sha256)`

- Reads Apollo's persisted query manifest (`format: "apollo-persisted-query-manifest"`, `version: 1`) or Relay's flat map.
- `digest:` is `:sha256`, `:sha1`, `:md5` or `false`.
- `fetch(id)` answers the operation (`id`, `name`, `body`, `document`, all frozen) or nil. `size` counts them.
- Raises `PersistedQueries::ConfigurationError` at boot for: invalid JSON, an unreadable file, an unknown format or version, an id that is not the digest of its query, a query that does not parse, a duplicate id, an entry that is not an object, or an empty manifest. Messages never quote the file's queries.

`use GraphQL::Armory::PersistedQueries, store:, strict: false`

- `store:` answers `fetch(id)` with an object that has `body` and `document`, or nil. A Manifest, or your own store.
- `strict:` is `true` or `false`.
- Keeps a `query_class` the schema already set, and subclasses it.

Context keys: `operation_id` (a String; anything else is an unknown id), `armory_allow_raw_query` (only `true` allows).

## Guarantees and limits

- A request with an id runs only the stored document for that id, or nothing.
- In strict mode a raw query runs only when the app's context says `armory_allow_raw_query: true`. The plugin does not decide who is staff: your controller does.
- Queries built by your own code as `GraphQL::Query` objects (for example in `multiplex`) bypass the plugin's lookup. In strict mode they are not refused either: the check happens when the plugin's query class builds the query.
- The manifest lives in the server's code: adding an operation needs a deploy. See the runtime store below.
- Subscriptions: graphql-ruby re-runs a subscription with its printed query, which the plugin accepts when it matches the stored document. Subscriptions are not tested with persisted queries yet.

## Planned: a runtime store

The manifest is the simplest store: one file, no database, deployed with the code. Teams that ship clients independently of the server (mobile apps, several frontends) need operations published without a server deploy. That is planned for later, behind the same `store:` interface:

- **A database table** (ActiveRecord) holding operations per client, with the digest checked on write.
- **A sync endpoint** the client build calls to publish its operations, authenticated per client with an HMAC of the request body and a secret per client.
- **Several clients**, each with its own operations and secret, so one client cannot publish under another's name.
- **Archiving** operations that old app versions no longer use, without deleting their history.
- **Publishing without redeploying**: the server reads new operations as soon as they are synced.

Until then, any object that answers `fetch(id)` with an operation can be passed as `store:`.
