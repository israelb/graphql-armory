# Persisted queries

Your API runs the operations your clients were built with, and nothing else.

## The problem

A GraphQL endpoint accepts any query anyone writes. Authorization decides what each user may read, but the endpoint still:

- **Runs queries you never wrote.** Anyone with a token can send deep, wide or expensive queries, or explore the schema field by field to find something you forgot to protect.
- **Parses and validates every request.** A large query costs CPU before a single field resolves.
- **Sends the full query text on every request.** Mobile clients pay that in bandwidth.

## The solution

Your client's build step (Apollo's persisted query manifest generator, or the Relay compiler's `persistConfig`) writes every operation the app uses to a JSON file. The server loads that file and clients send the operation's id instead of its text:

- **An allowlist.** In strict mode the server refuses any query that is not in the file, before validating it, so a raw query cannot even probe field names.
- **Tamper-evident.** Every id must be the digest (SHA-256 by default) of its query. A manifest edited by hand to put another query behind an id is refused when the app boots.
- **Parsed once.** Each stored query is parsed at boot and handed to graphql-ruby as a document, so a request skips parsing.
- **Smaller requests.** The client sends a 64-character id and the variables.
- **Both engines.** It hooks only `Schema.query_class`, so it works on the interpreter and on `Execution::Next`.

## Who does what

Two separate pieces work together. Your client tooling writes the list; this gem enforces it on the server.

| Piece | Who provides it | What it does |
|---|---|---|
| `persisted-queries.json` | Apollo or Relay, in your client's build | Lists every operation the app uses. You do not write or edit it by hand. |
| `PersistedQueries::Manifest` | this gem | Loads the file at boot and checks that nobody edited it. |
| `use GraphQL::Armory::PersistedQueries` | this gem | Runs the operation a request names by id, and in strict mode refuses everything else. |

Think of an event: the client tooling prints the guest list, and this gem is the guard at the door. A list without a guard stops nobody. Apollo's own router (GraphOS Router, Enterprise plan) can enforce the list; Apollo Server's built-in `persistedQueries` option is only a cache (automatic persisted queries) and still runs any query. Open-source graphql-ruby has no equivalent (GraphQL-Pro has its OperationStore), so without this gem a Ruby API ignores the file and keeps running any query it receives.

Your part is to copy the file the client build produced into the server (for example as `persisted-queries.json` in the Rails root) and deploy it.

### What the file looks like

Apollo's manifest, written by `generate-persisted-query-manifest` (`@apollo/generate-persisted-query-manifest`):

```json
{
  "format": "apollo-persisted-query-manifest",
  "version": 1,
  "operations": [
    {
      "id": "6c5d8a12c92cffe7786b5a6d288f56d479973fd0f35b31bce215a4df9cf554ef",
      "name": "Invoices",
      "type": "query",
      "body": "query Invoices { invoices { number total } }"
    }
  ]
}
```

Relay's persisted output, written by `relay-compiler` with `persistConfig`, is a flat map of id to query:

```json
{
  "904cd33a4439518767fd75402dd7e47b": "query Invoices { invoices { number total } }"
}
```

Each id is the digest of its exact query text: SHA-256 in Apollo's manifest, MD5 in this Relay example (load it with `digest: :md5`). Change a query without regenerating its id and the app refuses to boot, naming that id.

A client then sends only the id and the variables:

```json
{ "operationId": "6c5d8a12c92cffe7786b5a6d288f56d479973fd0f35b31bce215a4df9cf554ef", "variables": {} }
```

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

`PersistedQueries.operation_id(params)` reads the id where clients send it: `operationId`, `extensions.operationId`, or Apollo's `extensions.persistedQuery.sha256Hash` (`extensions` may be a JSON string, as in GET requests). The first one present wins, in that order. It answers nil when there is no id, or when it is not a non-empty String. Params must have String keys, as Rack and Rails params do. An empty `query` sent with an id (a GET request with `query=`) counts as no query.

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

Relay's example network layer sends the id as `doc_id`. Pass it yourself: `operation_id: params[:doc_id]`.

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
- Works with your own `query_class`, whether it is set before `use`, after it, or in a child schema: the plugin subclasses it.
- `use` it once per schema hierarchy. A second `use`, on the same schema or a child, raises instead of replacing the first one's settings.
- A store whose `fetch` raises or answers something without `document` makes the request raise: it fails closed, as an exception.

Context keys: `operation_id` (a String; anything else is an unknown id), `armory_allow_raw_query` (only `true` allows).

## Guarantees and limits

- A request with an id runs only the stored document for that id, or nothing.
- In strict mode a raw query runs only when the app's context says `armory_allow_raw_query: true`. The plugin does not decide who is staff: your controller does.
- Queries built by your own code as `GraphQL::Query` objects (for example in `multiplex`) bypass the plugin's lookup. In strict mode they are not refused either: the check happens when the plugin's query class builds the query.
- In strict mode, schema introspection run through the plugin is refused too. `Schema.to_json` and `rake graphql:schema:json` need `context: { armory_allow_raw_query: true }` (the rake task's `load_context`). `Schema.to_definition` and `Schema.validate` are not affected.
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

## References

- Apollo Client: [Persisted queries](https://www.apollographql.com/docs/react/data/persisted-queries) — generating the manifest with `@apollo/generate-persisted-query-manifest` and sending ids.
- Apollo iOS: [Persisted queries](https://www.apollographql.com/docs/ios/fetching/apqs).
- Relay: [Persisted queries](https://relay.dev/docs/guides/persisted-queries/) — `persistConfig`, local persisting to a file, `doc_id` in the network layer.
- Relay: [Compiler config](https://relay.dev/docs/getting-started/compiler-config/).
