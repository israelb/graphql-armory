# Response caching

A repeated persisted operation is answered from a store without running, and an answer is only stored when nothing the cache could not see took part in it.

## The problem

Many reads are the same question asked again: a catalog page, a pricing table, a dashboard a user reloads every few seconds. graphql-ruby has no response cache, and an HTTP cache in front of the app does not help: GraphQL is usually one POST to one URL, so nothing outside the app can tell two requests apart. Teams end up with one of two homemade fixes, and both fail open:

- **`Rails.cache.fetch` around a resolver** caches records without the authorization that should run on them.
- **A cache around the controller, keyed by the query string,** serves one user's answer to the next. A key that forgets one input (the viewer, the tenant, the locale, the API version, a visibility rule) leaks data or serves the wrong schema, and nothing tells the team which input they forgot.

## The solution

You declare, on fields and types, whether an answer may be cached, for how long and for whom. Nothing is cached that is not declared:

- **Declared per field and type.** `cache_fields ttl: 300, scope: :public, reason: "..."` on a type, `cache: { ttl: 60 }` or `cache: false` on a field. An operation is cached only if every field it selects is declared, for the smallest TTL among them.
- **Persisted operations only.** Only a query that [PersistedQueries](persisted-queries.md) ran from its allowlist is looked up. A raw query, a mutation, a subscription and a query your own code builds always run.
- **Everything graphql-ruby can see the answer depend on is in the key, or the answer is not stored.** The key holds the schema, the document, the declared variables, the version, the engine and, for per-viewer answers, the principal's class and id. While the run that would fill the cache executes, the context records every key it reads. A read the key does not hold, and a policy consulted for an answer meant for everyone, keep the answer out of the store.
- **Per viewer or public.** `scope: :viewer` (the default) answers only the principal it was computed for. `scope: :public` answers everyone, and it needs a `reason:` that [the audit](#the-audit) lists.
- **A hit costs what the run cost.** The client is charged the [Points](rate-limiting.md#cached-responses) the run was charged, so a hit is neither a bypass of the budget nor a way to learn that someone else asked first.
- **Purges that stick.** `Caching.purge` by tag, type, viewer or everything, and a run that started before a purge cannot undo it, even across processes and a store reset.
- **Fails open to computing, never to serving.** A broken, slow, poisoned, forged or reset entry is a miss and the query runs.
- **Both engines.** It hooks `multiplex` and `multiplex_next`, so it works on the interpreter and on `Execution::Next` (graphql 2.6.2 or later).

Read [Guarantees and limits](#guarantees-and-limits) before putting `scope: :public` on anything: the cache cannot see the database, the clock or a thread-local tenant.

## How to use it

### Installing

PersistedQueries is required. Add this plugin after it (either order loads; the first request checks it) and before any `rescue_from`:

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::PersistedQueries, store: PERSISTED, strict: true
  use GraphQL::Armory::Caching,
    store: GraphQL::Armory::Caching::RedisStore.build(redis: Redis.new(url: ENV.fetch("CACHE_REDIS_URL"))),
    encoder: AppEncoder,                              # required with RedisStore: entries are sealed with it
    release: ENV.fetch("GIT_SHA"),                    # required: a deploy never reads another deploy's answers
    viewer: :current_user,                            # the context key that holds the principal
    vary: { locale: :locale, tenant: -> { Current.tenant&.id } },
    sinks: [GraphQL::Armory::Telemetry::Notifications]

  rescue_from(ActiveRecord::QueryCanceled) { nil }    # after `use`: a run this handler answered is never stored
end
```

Pass the persisted operation id in the context, as PersistedQueries asks, and read what the cache did from the result:

```ruby
result = AppSchema.execute(
  params[:query],
  variables: params[:variables],
  operation_name: params[:operationName],
  context: {
    current_user: current_user,
    locale: I18n.locale,
    operation_id: GraphQL::Armory::PersistedQueries.operation_id(params)
  }
)
Rails.logger.info("graphql cache #{result.context[:response_cache]}")  # { status: :hit, reason: nil, scope: :public, ttl: 300, age: 12 }
```

Every option is checked at boot and raises `GraphQL::Armory::Caching::ConfigurationError` when it is wrong. The [reference](#reference) lists them. These also raise:

- A second `use` in one schema hierarchy.
- A `rescue_from` registered before `use`, on the schema or a parent. The plugin wraps the handlers registered after it so that a run a handler answered is flagged and never stored (`:rescued`); it cannot wrap one registered before. Move `use` above `rescue_from`. A handler a parent registers after a child's `use` makes that child's requests raise.
- A `max_ttl:` larger than the store's own `max_ttl` (see [Stores](#stores)).
- A schema without PersistedQueries, on its first request.

### Declaring what may be cached

Put `Caching::Base` in your base field and object classes (and in a base interface, after `include GraphQL::Schema::Interface`):

```ruby
class Types::BaseField < GraphQL::Schema::Field
  include GraphQL::Armory::Caching::Base
end

class Types::BaseObject < GraphQL::Schema::Object
  include GraphQL::Armory::Caching::Base
  field_class Types::BaseField
end

class Types::Product < Types::BaseObject
  authorize :none, reason: "public catalog"
  cache_fields ttl: 300, scope: :public, tags: ["catalog"], reason: "the catalog is the same for every viewer and tenant"

  field :name, String, null: false
  field :price, Money, null: false, cache: { ttl: 60, tags: ["pricing"] }   # narrower: the operation's TTL becomes 60
  field :stock_level, Integer, null: false, cache: false                    # selecting it makes the operation uncacheable
  field :download_url, String, null: false, cache: false                    # a signed, expiring URL
end

class Types::Invoice < Types::BaseObject
  cache_fields ttl: 30                                                      # scope defaults to :viewer
end
```

`cache_fields ttl:, scope: :viewer, tags: [], reason: nil` sets the default for the fields **that type declares itself**. `cache: { ttl:, scope:, tags:, reason: }` on a field declares or narrows one, and `cache: false` forbids it.

- **A field may only narrow its type's default:** a smaller TTL, or `:viewer` over `:public`. A wider one raises `ConfigurationError` when it is defined, naming the field. Its tags are added to the type's.
- **`scope: :public` needs `reason:`.** Say why the answer is the same for every viewer, tenant and locale. The audit lists every one.
- **`ttl:` is a positive Integer of seconds.** A stored answer never lives longer than `max_ttl:` (`max_viewer_ttl:` for `:viewer` answers, at most 300 seconds), whatever the declaration says; the audit reports a declaration above them (`:ttl`).
- **`tags:` are Strings you can [purge](#purging) by.** A tag says what the selection declared, not which records the data came from.
- **A field without its own `ttl:`** (`cache: { tags: ["x"] }`) is completed from its type's `cache_fields`. On a type with none, it raises `ConfigurationError` the first time an operation selects it, and the audit reports it as `:incomplete`.

What an operation gets from its fields:

| It selects | The operation is |
|---|---|
| Fields that are all declared | Cacheable for the smallest TTL among them, `:public` only if every field is `:public`, with every declared tag and a `type:<Name>` tag for each type it can return |
| A field no declaration reaches | Not cached (`:undeclared_field`) |
| A field with `cache: false` | Not cached (`:forbidden_field`) |
| `__schema` or `__type` | Not cached (`:introspection`) |
| Any directive other than `@skip` and `@include`, anywhere in the document | Not cached (`:directive`), unless the directive's class declares `cache_safe` |
| A field the schema does not show to this request | Not cached (`:unknown_field`), and graphql-ruby answers the validation error |
| Only `__typename` | Not cached: nothing declared a TTL (`:undeclared_field`) |

Rules worth knowing:

- **An inherited field keeps the declaration of the class or interface that declared it.** A subclass's wider `cache_fields` never reaches the fields it inherits, and an implementation's `cache_fields` does not reach an interface field it does not redefine. To cache an inherited field, declare it where it is defined, or redefine it.
- **A field on an interface or union position is judged on the interface and on every possible type's own definition of that name.** If one implementation forbids it or makes it `:viewer`, the whole operation is, whatever type the data turns out to be. Fragments take their type condition as the owner.
- **`@skip` and `@include` are ignored: both branches count,** so a field behind `@skip(if: true)` must still be declared. The policy never depends on variables.
- **Relay connections.** The fields graphql-ruby generates (`edges`, `nodes`, `node`, `cursor`, `pageInfo` and `PageInfo`'s fields) take the declaration of the field that returned the connection. A field you add to a connection (`totalCount`), and a generated one you resolve yourself (your own `def nodes`, a `resolver_method:`, a resolver class or an extension), needs its own.
- **A custom directive that does not change the data** (a client hint, a trace label) can declare it, with the same `Base`:

  ```ruby
  class Directives::Trace < GraphQL::Schema::Directive
    include GraphQL::Armory::Caching::Base
    locations FIELD
    cache_safe reason: "labels the request for the client's tracer; it never changes the data"
  end
  ```

  A directive in the document that is not declared this way, or that the schema does not define, makes the operation uncacheable.
- Declarations on a mutation or subscription root, and `cache_fields` on an input type, are never used. The audit reports them as `:ignored`.

### Who an answer is for

`scope: :viewer` means one answer per principal. The principal is whatever `viewer:` names in the context, and the key holds its class name and id, so `User 7` and `AdminUser 7` never share an entry:

```ruby
use GraphQL::Armory::Caching, store: store, release: ENV.fetch("GIT_SHA"),
  viewer: :current_user,                                 # default id: principal.id
  viewer_id: ->(principal) { principal.uuid }            # optional: a non-empty String or an Integer
```

- Without `viewer:`, a `:viewer` operation is never cached (`:viewer_unconfigured`).
- `viewer_id:` must answer a non-empty String or an Integer. Anything else, or a principal of an anonymous class, raises `ConfigurationError` on the query: that is your setup, not the client's.
- **Anonymous requests.** A request whose `viewer:` key is absent, nil or `false` is anonymous. By default (`anonymous: :uncacheable`) it never stores or hits a `:viewer` operation (`:anonymous`). `anonymous: :shared, anonymous_reason: "..."` lets every anonymous request of one form share one entry per key, and the audit lists the reason. Absent, nil and `false` stay three different entries, since a resolver can tell them apart.
- `scope: :public` answers hold no viewer, and a `:public` run that reads the `viewer:` key is not stored.
- **The viewer key and Authorization.** The authorization adapter reads the user from the context like any other code. With Pundit that key is `user_key:` (default `:current_user`): make `viewer:` the same key, or the run reads a key the cache key does not hold and is not stored. With CanCanCan, a context that holds `:current_ability` is never cached (`:current_ability`): the ability is an object the key cannot identify. See [Authorization](authorization.md#with-response-caching).

### Inputs you must declare

**First, what the cache cannot see.** The key holds the schema, the document, the declared variables, the version, the visibility profile, the engine, the per-request limits, the viewer (for `:viewer` answers) and your `vary:` values. Nothing else. An answer that depends on the database, the clock, `ENV`, `Current` attributes, `I18n.locale`, a feature flag read from a global, or the state of an object held in the context (`context[:current_user].role`) is stored under a key that does not hold that input, and served to whoever asks next.

Put every such input in `vary:` as a callable that takes no arguments:

```ruby
vary: { locale: -> { I18n.locale }, tenant: -> { Current.tenant&.id } }
```

`scope: :public` is your promise that you did. The audit cannot check it.

`vary:` is a Hash of name to a context key (the value enters the key whole, and counts as covered, below) or to a callable. Values are encoded with their type: `"en"` and `:en` are different keys, and so are `1` and `"1"`, inside Arrays and Hashes too. A value of another type (an object, a `Date`) makes the request uncacheable (`:vary_value`). An absent context key is not a nil one.

**What the cache does see: context reads.** Every query's context records, from the moment it is built (before the visibility profile is picked, before validation), every key read through `context[...]`, `fetch`, `dig` and `key?`, whether the key is there or not: reading an absent `:flags` is an answer that depends on there being no flags. `to_h`, `to_hash`, `namespace(nil)` and `scoped_context` read the whole context. After the run, every key read must be covered:

- the `viewer:` key, for `:viewer` answers only;
- each `vary:` entry given as a context key (`vary: { locale: :locale }`): its whole value is in the key. A `vary:` callable covers nothing;
- graphql-ruby's own machinery keys, and `neutral_keys:`.

Any other key, or a whole-context read, and the answer is not stored (`:cache_skipped`, `reason: :context_read`, with the key's name).

**`neutral_keys:`** declares a context key that never changes the answer for any reader, with the reason the audit lists: `neutral_keys: { request_id: "logging only" }`. It cannot name the `viewer:` key.

**Writes.** `context[key] = ...`, `delete`, `scoped_merge!`, `scoped_set!` and `context.scoped` are recorded too. Writing a key the cache key covers, or one the query already read, means the answer no longer matches its key: it is not stored (`:context_written`). A value a resolver passes down with `scoped_set!` and reads below is the query's own and is fine; a read of the same key outside that subtree still reads your context and counts.

**Several queries, one Hash.** Queries of one multiplex given the same context Hash object see each other's writes. A write by one of them to a key another read or covers, or a whole-context read by any of them, keeps the others from being stored too. Give each query its own Hash.

**Neutral readers.** Tracers, loggers and limiters read the context for reasons that do not change the answer. Wrap such code in `GraphQL::Armory::Caching.neutral(context) { ... }`: its reads are not recorded, in that code only (the same key read by a resolver still counts). It answers the block's value. Keep it to reads that cannot change `data`. A value written inside it and read afterwards still counts as read. The gem's own limiters, Versioning's decision and [Telemetry](telemetry.md#with-response-caching)'s sinks already read this way.

**Your own context class.** Methods your `context_class` adds (`def current_user = @provided_values[:current_user]`) read the context without being recorded. Declare each public one in `context_methods:` with a reason, or queries on that context run uncached (`:context_method`):

```ruby
use GraphQL::Armory::Caching, ..., context_methods: { current_user: "reads context[:current_user], the viewer: key" }
```

Overrides of `[]`, `fetch`, `dig` and the like must call `super`; the audit reports those that do not (`:context_class`). Declaring a method is your word that it reads only covered keys.

**What is never seen:** a read through `instance_variable_get(:@provided_values)` or through a reference to the Hash your controller kept, and contexts graphql-ruby builds outside your class (`Query::Partial`, which is never cached).

### What is cached and when

A query is looked up only when all of these hold:

- the request path built it (not a `GraphQL::Query` or `Query::Partial` your code built);
- it is not a mutation, nor in a call with one, and not a subscription;
- neither PersistedQueries nor Versioning refused it;
- it carries none of `root_value:`, `validate: false`, `static_validator:`, `warden:` or a changed `use_visibility_profile:`;
- PersistedQueries marked it persisted;
- its context holds neither `armory_full_schema` nor `current_ability`, and its context class adds no method you did not declare.

Then every field it selects must be declared, and the key must build.

A stored entry is served only when it opens under that exact key, its epoch is the store's and its sequence is not ahead of the store's, it has not expired at the store's clock, its sealed tag list matches the one beside it, no tag was purged after it was stored, and, with a Points limiter, it recorded a cost. Any failed check is a miss (`:cache_entry_rejected`) and the query runs.

After a miss runs, its answer is stored only when:

- it has no `errors`, and its `data` is a Hash of JSON-native values (String, Integer, finite Float, true, false, nil, Array, Hash with String keys): a hit must equal the miss, and a Symbol or a `Time` would come back as text;
- its only response extension is the limiters' `rateLimit`, which is never stored;
- no `rescue_from` handler answered;
- every context key it read is covered, and it wrote no covered key and no key it had already read;
- for a `:public` answer, no authorization policy was consulted (see [Authorization](authorization.md#with-response-caching));
- with a Points limiter, the run recorded its cost;
- the sealed entry fits `max_entry_bytes`;
- the run ended within `max_ttl` of its lookup, so a purge that landed meanwhile has not been forgotten.

A store that raises on a lookup or a write is reported to `on_store_error:` and the query runs uncached. The [reasons table](#reasons) lists every reason a query is not cached or not stored.

### The cache key

Every entry is stored under a keyed digest (HMAC-SHA256) of one canonical JSON Array. No component is concatenated as text, so none can forge a separator:

```
["armory-cache/2", release, schema name, schema digest, engine, document digest, selected operation name,
 declared variables, version label, visibility profile, max_depth, max_complexity, scope, viewer, vary]
```

- **Release and schema.** `release:` keeps one deploy from reading another's answers. The schema digest is SHA-256 of `to_definition` for the query's version and visibility profile, computed on the first request that needs it (not at `use`) and kept per version and profile, so a schema reloaded in development never shares answers across definitions.
- **Document and operation.** A digest of the printed document, and the name of the operation that runs. A persisted operation's shared document is printed once per process.
- **Variables.** Only the variables the operation declares, as `[name, sent?, value]` sorted by name, before coercion. A variable sent as null is not one that was not sent; undeclared variables are ignored and cannot flood the store; `1` and `1.0` are different keys; a Hash keeps the key order it was sent in. Values must be JSON (see above); a Symbol, a `Date`, `NaN` or any other object makes the request uncacheable (`:variables`).
- **Version.** The resolved [Versioning](versioning.md#with-response-caching) label, not the client's raw header.
- **Engine.** The interpreter and `Execution::Next` never share an answer.
- **Viewer and `vary:`.** As above.
- **In the store.** Only `prefix + hex digest`. No viewer id, variable, tag or operation name appears in clear.

Without `encoder:`, the digests use a random key per process, so entries are not shared between processes: fine for a `MemoryStore`, which is per process anyway.

### Purging

```ruby
GraphQL::Armory::Caching.purge(AppSchema, all: true)             # everything (the store replaces its epoch)
GraphQL::Armory::Caching.purge(AppSchema, viewer: user)          # one principal's answers, by [class name, viewer_id]
GraphQL::Armory::Caching.purge(AppSchema, viewer: :anonymous)    # the shared anonymous answers
GraphQL::Armory::Caching.purge(AppSchema, tag: "pricing")        # a declared custom tag
GraphQL::Armory::Caching.purge(AppSchema, type: Types::Invoice)  # best effort, see below
```

Pass exactly one. Tags are digested with the same keyed digester the entries were stored with, so the store never sees one in clear.

- **`type:` is best effort.** It reaches every answer whose selection can return an object of that GraphQL type. It does not reach data derived from that type's records through another type's field (`Product.totalSales` computed from invoices), because tags do not know where the data came from. For derived data, declare a custom tag and purge it.
- **A purge that fails raises.** If the store fails, `purge` raises `GraphQL::Armory::Caching::PurgeError` (its message names only the error's class) and records `:cache_store_failed`. A silently failed purge would serve stale data until the TTL. Retry it, for example from a job; purging twice is harmless.
- A successful purge records `:cache_purged` with its `kind`, and `type` for a type purge; never the tag or the viewer.

Purge when the data changes, because the TTL is only an upper bound:

```ruby
class Price < ApplicationRecord
  after_commit { PurgeCacheJob.perform_later(tag: "pricing") }
end

class PurgeCacheJob < ApplicationJob
  retry_on GraphQL::Armory::Caching::PurgeError, wait: 5.seconds, attempts: 10

  def perform(tag:) = GraphQL::Armory::Caching.purge(AppSchema, tag: tag)
end
```

**Two things a TTL alone gets wrong, and what to purge:**

- **A revoked permission keeps serving.** A `:viewer` answer keeps the policy's decision for up to its TTL, so a viewer who lost access still gets the cached answer until it expires. `max_viewer_ttl:` (at most 300 seconds) bounds it. Call `purge(viewer: user)` on a role change and on logout.
- **Data someone hid keeps showing to others.** When user B makes a profile private, answers already cached for other viewers that hold B's data keep showing it up to their TTL (`max_viewer_ttl` for `:viewer` answers, `max_ttl` for `:public` ones). `purge(viewer: B)` does not reach them: they are other viewers' entries. Put a custom tag on such data and purge it on the change.

**How a purge sticks.** The store keeps, in one record, an `epoch`, a purge sequence `seq` and one mark per purged tag. A purge increments `seq` and marks each of its tags with the new value, atomically. A lookup answers `seq` and `epoch` with the entry, and the run that follows a miss writes with that `seq` and `epoch`. The write is refused, and a read rejects the entry, when the epoch changed or one of its tags carries a mark greater than its `seq`. So a purge that lands while a run is computing, or between the run and its write, invalidates what that run would store.

- **A store reset counts as everything purged.** If the record is lost (evicted, flushed, a failover to a replica without it), a new one is created with a new epoch and every older entry fails the epoch check. An entry whose `seq` is ahead of the store's (a replica that lost recent increments) is rejected too.
- **Marks are pruned** by the purge itself, up to 100 per purge, once older than `max_ttl` (on Redis, the longest `max_ttl` of the stores sharing the prefix). By then every entry a mark could reject has expired: entries are stamped with their lookup time, no TTL exceeds `max_ttl`, and a run that ends more than `max_ttl` after its lookup is not stored.

### Rate limiting

A hit runs no analyzer, so without help it would be free: a bypass of the budget, and an oracle, since a client that sees its budget not move learns that someone else asked the same public question. So the cache charges each hit through `Points`. The entry holds the cost its run was charged, read from that query's own record, and every `Points` limiter of the schema charges a hit that cost as it charges a run: the same keys, limits, soft mode and store, the same `context[:rate_limit_points]`, `rateLimit` extension and `Points.headers`. A client over budget gets the limiter's own `RATE_LIMITED` refusal and nothing from the cache; `context[:response_cache]` then reads `status: :hit, reason: :rate_limited`.

- Only a query a `Points` limiter guards is charged. Without one, a hit costs nothing.
- When a `Points` limiter guards the query, an answer without a recorded cost is not stored (`:cost_unknown`), and an entry with none is not served: a hit could not be charged.
- **`Time` does not bound hits, and `Concurrency` takes no slot for one.** A hit runs nothing. If you rely on `Time` alone to bound expensive reads, cached reads are outside it.

See [Rate limiting: cached responses](rate-limiting.md#cached-responses).

### Stores

A store keeps the answers and the record that makes purges stick. Every key and tag it sees is a keyed digest: nothing in it names a viewer, a tag, a variable or an operation in clear. Entries are JSON, never `Marshal`: reading one never builds an object. Pass a `MemoryStore` or a `RedisStore`, or any object that answers `lookup`, `write`, `purge` and `purge_all` like them. `Store::Null`, a cache that stores nothing, is refused at boot.

**`MemoryStore`**: in this process's memory, for tests, development and single-process servers.

```ruby
GraphQL::Armory::Caching::MemoryStore.new(max_bytes: 64 * 1024 * 1024, max_ttl: 3600)
```

Entries are evicted least recently used first once they pass `max_bytes` (default 32 MiB), and an entry larger than `max_bytes` is not stored. The purge record is never evicted. Each process has its own entries and its own purge record, so a purge reaches only the process it runs in.

**`RedisStore`**: shared by every process of the app. Use it in production, with an encoder.

```ruby
GraphQL::Armory::Caching::RedisStore.build(
  redis: Redis.new(url: ENV.fetch("CACHE_REDIS_URL")),
  prefix: "graphql-armory:cache:",   # default
  max_ttl: 3600,                     # the longest TTL it stores; give it use's max_ttl: or more
  purge_replicas: nil,               # WAIT for n replicas after each purge
  purge_timeout: 1                   # seconds WAIT may take
)
```

- Each operation is one Lua script, so it is atomic and one round trip, and the clock is Redis's own `TIME`, so processes on different machines agree on it. It needs Redis 5 or later and a client that answers `eval`, `evalsha` and `call` (redis-rb 4.8 or later). The gem does not depend on the redis gem: add it to your Gemfile.
- `<prefix>meta` is one hash without a TTL that holds the epoch, the purge sequence and the purge marks. `<prefix>e:<key digest>` is one hash per entry, expiring with it. Under a `volatile-*` eviction policy the meta hash is never evicted; under an `allkeys-*` policy it can only be evicted whole, which every process reads as "everything purged".
- **Use a Redis of its own for the cache.** Someone can fill it with distinct variable values and push other entries out. PersistedQueries and RateLimits keys need `noeviction`; a cache needs eviction.
- **Redis Cluster:** every script touches the meta hash, so the prefix needs a hash tag that puts every key in one slot: `prefix: "graphql-armory:{cache}:"`.
- **Replicas.** A purge acknowledged by a primary that fails before replicating it is lost. With `purge_replicas: n`, the store runs `WAIT n` after each purge and raises `PurgeError` when fewer replicas acknowledged it within `purge_timeout`. A lost epoch or `seq` is detected on its own; a lost mark alone is not.
- `RedisStore.new`, with no Redis wired, caches nothing and raises on a purge.

**`max_ttl` must agree.** A store prunes purge marks older than its own `max_ttl`, so no entry may outlive that. `use` raises `ConfigurationError` at boot when its `max_ttl:` is larger than the store's, naming both. Give the store the same `max_ttl:` as `use`, or more.

**There is no `Rails.cache` store.** It serializes with `Marshal` by default, so whoever can write it could run code in the app.

#### Security of the store

Treat the store as hostile: whoever can read it must learn nothing, and whoever can write it must not make the app serve anything it did not store under that key.

- **Seal entries with an encoder** (`encoder: AppEncoder`, any [`GraphQL::Armory::Encoder`](encrypted-ids.md#sealing-other-data) subclass or `Encoder.versioned(...)` chain). `encoder:` is required with `RedisStore` and optional with `MemoryStore`. Each entry is encrypted with AES-256-GCM under a key derived for caching alone, bound to the entry format, the key it is stored under and the encoder's tag. An entry copied under another key, forged in clear, edited, or written by an app with another key or tag does not open: it is a miss (`:cache_entry_rejected`, `reason: :decrypt`) and the query runs. A sealed entry is never accepted as an ID or a cursor, nor the reverse.
- **After opening, an entry that names another key inside** (`:key`) **or has another format** (`:format`) is rejected too.
- **Keys and tags are keyed digests** (HMAC-SHA256 with the encoder's `cache-digest` key), so a digest cannot be checked against a guess without the key. The store keeps each entry's tag digests beside its sealed blob to read their purge marks in one round trip; the sealed copy holds the same list, and a mismatch after opening rejects the entry (`:tags`).
- Without an encoder, `MemoryStore` uses a random per-process key and entries are plain JSON: use that only for a store nobody else can write.
- **`Encoder::Legacy` and `Encoder::Null` cannot seal:** `use` refuses them at boot, as it refuses an encoder without a key.
- **Rotating the key.** With `Encoder.versioned(New, Old)`, new entries are sealed with `New` and old ones still open, but keys and tags are digested with `New`, so entries stored before the rotation are no longer found. A rotation empties the cache in effect, and nothing stale is served.

### Watching the cache

`context[:response_cache]` is a frozen Hash for each query, for your controller or log, also kept in the query's `namespace(:graphql_armory)[:response_cache]`:

```ruby
{ status: :hit | :stored | :skipped, reason: nil | :rate_limited | <a reason>, scope: :public | :viewer | nil, ttl: 300, age: 12 }
```

`age` is whole seconds since the answer was stored, on a hit only. `ttl` is the stored TTL, on a hit or a store. For a `:skipped` query, `reason` is one of the [reasons](#reasons). It holds no key, viewer, variable or operation.

`extensions: true` adds `"cache" => { "hit" => true, "age" => 12 }` to a hit's response. It is off by default: it tells the client what response timing already tells it, more precisely.

The cache also records [signals](#signals) to your `sinks:`: hits, stores, skips and their reasons, rejected entries, store failures and purges. They are the place to see how often a reason keeps a query out of the cache.

### With other modules

- **[PersistedQueries](persisted-queries.md#with-response-caching)** decides first and marks the queries that run a stored operation. Only those are looked up.
- **[Versioning](versioning.md#with-response-caching)** decides first. Its read of `armory_version` is neutral, the resolved label and the version's schema are in the key, and a refused version is never looked up. Your own code reading `context[:armory_version]` still counts; read the version with `Versioning.version(context)`.
- **[Authorization](authorization.md#with-response-caching)** marks a query wherever a policy or ability is consulted. A marked query is never stored as `:public`. An `authorize :none` bypass marks nothing.
- **[Rate limiting](rate-limiting.md#cached-responses)** charges hits through `Points`.
- **[Encrypted IDs](encrypted-ids.md#sealing-other-data)**: the encoder seals entries and keys the digests. Encrypted cursors carry a fresh nonce in every response, so a "next page" request has a key nobody else will produce: expect few hits there.
- **[Telemetry](telemetry.md#with-response-caching)**: the same `sinks:` and `on_sink_error:`; sinks read the context neutrally.
- **Multiplex.** Each query is judged alone, except that a mutation anywhere in the call keeps every query of the call from being cached (`:multiplex_mutation`). The misses run together, so they keep graphql-ruby's shared dataloader. A multiplex-wide analyzer sees only the misses.

### The audit

```ruby
GraphQL::Armory::Caching::Audit.(AppSchema)                       # => report
GraphQL::Armory::Caching::Audit.(AppSchema, strict: true)         # information fails it too
```

```ruby
# spec/graphql/cache_spec.rb
require "graphql/armory/caching/rspec"

RSpec.describe AppSchema do
  it { is_expected.to have_safe_cache_declarations }
  it { is_expected.to have_safe_cache_declarations(own_checks: { Types::Product => { authorized?: "reads only the record's class" } }) }
end
```

```
bundle exec rake "graphql_armory:cache:audit[AppSchema]"          # prints the report, exits 1 on problems
```

The audit reads the schema's classes and never runs a query, and never runs at boot or during a request: put the spec or the rake task in CI. It walks every type the roots, the orphan types and `schema.types` reach, hidden or not, so every version of a Versioning schema is read at once.

| Kind | What it means | Fix |
|---|---|---|
| `:plugin` | `Base` is included, or declarations exist, with no `use GraphQL::Armory::Caching`; or caching is installed without PersistedQueries | Add the missing `use` |
| `:public_over_rule` | A `:public` declaration on a field where Authorization decides per user: a rule other than `authorize :none` on the type that serves or defines it or on a type it returns (an interface's or union's possible types, a connection's nodes, so a scoped list too), a field, resolver or argument rule, `visible_when:`, `observe:`, `loads:` or `find_by:` | Make it `:viewer`, or bypass the rule if the data really is public |
| `:own_check` | Your own `visible?`, `authorized?`, `scope_items`, `authorized_new` or `wrap` on a class a `:public` declaration reaches: the audit cannot read what it does | Remove it, or declare it in `own_checks:` with a reason |
| `:context_class` | Your `context_class` overrides `[]`, `fetch`, `dig`, `key?`, `to_h`, `namespace`, `scoped_context` or a write method without calling `super`, or adds public methods not in `context_methods:`; or `context_methods:` names a method it does not add | Call `super`; declare the methods |
| `:viewer_unconfigured` | A `:viewer` declaration exists and `viewer:` is not set: those operations never cache | Set `viewer:`, or declare `:public` |
| `:ttl` | A TTL above `max_ttl:`, or a `:viewer` TTL above `max_viewer_ttl:` | Lower it |
| `:ignored` | A declaration on a mutation or subscription root, or `cache_fields` on an input type: never used | Remove it |
| `:incomplete` | A field's `cache:` leaves out `ttl:` and its type has no `cache_fields` to complete it: never cached | Give it `ttl:`, or its type `cache_fields` |
| `:directive` | An executable custom directive without `cache_safe`: operations that use it never cache. Information | Declare `cache_safe reason: "..."` if it does not change the data |

Information does not fail `ok?` unless `strict: true`. Every declaration is listed apart, with its reason, so a reviewer can read it: each `:public` declaration, `anonymous: :shared`, each `neutral_keys:`, `context_methods:` and `own_checks:` entry, and each `cache_safe` directive. `own_checks:` is also a `use` option, for the rake task, which cannot take arguments. It changes nothing at runtime.

Each problem has a `location` (`path:line`) where your code wrote what it is about, as in the [Authorization audit](authorization.md#the-audit).

**What a pass means.** `ok?` covers only what Authorization's chokepoints decide. An `authorize :none` type whose resolver scopes by `Current.user` passes the audit, and a `:public` declaration on it serves one user's data to another. Every input the audit and the recorder cannot see belongs in `vary:`. Whether your overrides of the context's methods call `super` is read from the compiled instructions, which only CRuby gives: elsewhere the audit reports every override as one it cannot clear.

### Testing with response caching

`Caching::Controls` holds a small schema and its persisted operations to test against: `Controls::Schema.example(authorization: true, adapter: nil, next_default: false, caching: { store:, release:, ... }, sinks: [])` (`caching:` takes the `use` options; without it caching is not installed), `Controls::Operations` (a `:public` operation, a `:viewer` one, one with a declared variable and one per refusal), `Controls::Context.example(operation:, viewer:, locale:)` and `Controls::Context.anonymous`, `Controls::Viewer.example(id:, admin:)` (a `User` and an `AdminUser` with the same id) and `Controls::Store.example`.

`Store::Substitute` is a store on a clock your test moves (`now = ...`), that keeps the store contract, records its calls (`calls`), and fails or answers what it is told: `fail_with(error, on: :write)`, `answer(:lookup, lookup)`, `reset!` (the purge record is gone: every older entry fails the epoch check), `poison(key, blob)`. Tests read what the object recorded, not call expectations:

```ruby
caching = GraphQL::Armory::Caching
seen = []
store = caching::Controls::Store.example
schema = caching::Controls::Schema.example(
  caching: { store: store, release: "test", viewer: :current_user, sinks: [->(signal, data) { seen << [signal, data] }] }
)

context = -> { caching::Controls::Context.example(operation: "names") }
schema.execute(context: context.())   # a miss: stored
schema.execute(context: context.())   # a hit

seen.map(&:first).select { |signal| signal.to_s.start_with?("cache_") }   # => [:cache_stored, :cache_hit]
```

The decision itself is `Caching::Gate`: `Gate.build(schema, store:, digester:, telemetry:, release:, ...)` takes `use`'s options and wires the real walk, keyer, codec and charge, `gate.(queries, engine:)` answers one `Decision` per query and `gate.store(query, decision, result)` answers `:stored` or the reason it was not. `Gate.new`, with nothing wired, passes every query through uncached and never touches the store (`Walk::Null`, `Keyer::Null`, `Charge::Null`, `Store::Null`). `Gate::Substitute` answers the decisions you tell it. `Recorder::Substitute` stands in for the recorder.

## Reference

`use GraphQL::Armory::Caching, store:, release:, encoder: nil, viewer: nil, viewer_id: nil, anonymous: :uncacheable, anonymous_reason: nil, vary: {}, max_ttl: 3600, max_viewer_ttl: 300, max_entry_bytes: 262_144, neutral_keys: {}, context_methods: {}, own_checks: {}, extensions: false, sinks: [], on_sink_error: nil, on_store_error: nil`

| Option | Default | What it is |
|---|---|---|
| `store:` | required | A `MemoryStore`, a `RedisStore`, or an object with `lookup`, `write`, `purge` and `purge_all`. `Store::Null` is refused. |
| `encoder:` | none | An `Encoder` subclass (or a `versioned` chain) that seals entries and keys the digests. Required with `RedisStore`. `Encoder::Legacy` and `Encoder::Null` are refused. |
| `release:` | required | A non-empty String that names the deploy (`ENV.fetch("GIT_SHA")`). |
| `viewer:` | nil | The context key (Symbol or String) that holds the principal. Without it, no `:viewer` operation is cached. |
| `viewer_id:` | `->(principal) { principal.id }` | Answers the principal's id, a non-empty String or an Integer. Needs `viewer:`. |
| `anonymous:` | `:uncacheable` | `:uncacheable` or `:shared`. `:shared` needs `viewer:` and `anonymous_reason:`. |
| `anonymous_reason:` | nil | Why every anonymous request may see one answer. Only with `anonymous: :shared`. |
| `vary:` | `{}` | name to a context key (covers that key) or a callable with no arguments (covers nothing). |
| `max_ttl:` | `3600` | The longest TTL stored, in seconds. Not above the store's `max_ttl`. |
| `max_viewer_ttl:` | `300` | The longest TTL of a `:viewer` answer. At most `300`. |
| `max_entry_bytes:` | `262_144` | A larger sealed entry is not stored (`:too_large`). |
| `neutral_keys:` | `{}` | context key to a reason: keys that never change an answer. Cannot name the `viewer:` key. |
| `context_methods:` | `{}` | method name to a reason, for the public methods your `context_class` adds. |
| `own_checks:` | `{}` | `{ Class => { method => "reason" } }`, as in Authorization. Read only by the audit. |
| `extensions:` | `false` | `true` adds `"cache" => { "hit" => true, "age" => n }` to a hit's response. |
| `sinks:`, `on_sink_error:` | `[]`, nil | See [Telemetry](telemetry.md). |
| `on_store_error:` | warns | A callable `(error, query)` called when the store raises; the query runs uncached. |

Declarations (`include GraphQL::Armory::Caching::Base`):

- `cache_fields ttl:, scope: :viewer, tags: [], reason: nil` on an object type or an interface.
- `field ..., cache: { ttl:, scope:, tags:, reason: }` or `cache: false`.
- `cache_safe reason:` on a directive class.

Calls:

- `Caching.purge(schema, all: false, viewer: nil, tag: nil, type: nil)`: exactly one. Raises `Caching::PurgeError` if the store fails.
- `Caching.neutral(context) { ... }`: runs the block without recording its context reads.
- `Caching::Audit.(schema, own_checks: {}, strict: false)`, `have_safe_cache_declarations(own_checks: {}, strict: false)` and `rake "graphql_armory:cache:audit[AppSchema]"`.
- `Caching::MemoryStore.new(max_bytes: 33_554_432, max_ttl: 3600, clock: ...)` and `Caching::RedisStore.build(redis:, prefix: "graphql-armory:cache:", max_ttl: 3600, purge_replicas: nil, purge_timeout: 1)`.

Errors: `Caching::ConfigurationError` (a declaration, an option or the schema is not set up the way caching needs), `Caching::PurgeError` (the store failed during a purge), both under `Caching::Error`.

### Reasons

The reason a query is not cached, or a miss is not stored, appears in `:cache_skipped` and in `context[:response_cache]`. Most are your declarations or your setup working as intended; read the "Look at" column when one is more frequent than you expect.

Before the lookup (the query runs uncached):

| Reason | Because | Look at |
|---|---|---|
| `:built_query` | The query was not built by the request path: a `GraphQL::Query` or `Query::Partial` your code built, or a request whose options carried `warden:`, `static_validator:`, `root_value:`, `use_visibility_profile:` or `validate: false` | Send requests through `execute` or `multiplex` |
| `:mutation`, `:subscription` | The operation is one | Nothing: they are never cached |
| `:multiplex_mutation` | Another query of the same call is a mutation | Run reads and mutations in separate calls |
| `:refused` | PersistedQueries or Versioning refused the request, or the app passed a `static_validator:` | The refusal's own signal |
| `:options` | The query carries `root_value:`, `validate: false` or a visibility profile you changed | |
| `:not_persisted` | PersistedQueries did not mark it persisted: a raw query, or one run with `armory_allow_raw_query` | [Persisted queries](persisted-queries.md#with-response-caching) |
| `:full_schema` | The context holds `armory_full_schema` | Only schema dumps set it |
| `:current_ability` | The context holds `current_ability`, an object the key cannot identify | Build the ability from the covered user key instead |
| `:context_method` | Your context class adds a public method not in `context_methods:` | Declare it, or make it private |
| `:unconfigured` | Nothing is wired: a gate, walk or keyer built with `new` | |

From the declarations:

| Reason | Because | Look at |
|---|---|---|
| `:undeclared_field` | A selected field has no declaration, or only `__typename` is selected | Add `cache:` or `cache_fields` |
| `:forbidden_field` | A selected field has `cache: false` | |
| `:directive` | A directive other than `@skip` and `@include` is in the document | `cache_safe` |
| `:introspection` | `__schema` or `__type` is selected | |
| `:unknown_field`, `:invalid_document` | A field, fragment or type is not in the schema this request sees | graphql-ruby answers the validation error |
| `:no_operation` | The document has no selected operation | |

From the key:

| Reason | Because | Look at |
|---|---|---|
| `:viewer_unconfigured` | A `:viewer` operation and no `viewer:` | Set `viewer:` |
| `:anonymous` | A `:viewer` operation, an anonymous request and `anonymous: :uncacheable` | `anonymous: :shared` |
| `:variables` | A declared variable's value is not JSON | |
| `:vary_value` | A `vary:` value of a type the key cannot hold | Return a String, Integer, Symbol, Float, true, false, nil, Array or Hash |
| `:version` | Versioning refused the version | |
| `:schema_unprintable` | graphql-ruby cannot print the schema: graphql 2.4 with json 3.x, on a schema that prints a deprecation reason or a string default | Use a graphql version that prints it |
| `:operation` | No operation could be selected | |
| `:key_scope` | The key's scope differs from the declarations' | Should not happen: report it |

After the run (a miss that is not stored):

| Reason | Because | Look at |
|---|---|---|
| `:errors` | The response has `errors` | |
| `:no_data` | `data` is nil | |
| `:non_json_data` | `data` holds something that is not JSON-native | |
| `:extensions` | The response has an extension other than `rateLimit` | |
| `:rescued` | A `rescue_from` handler answered | |
| `:context_read` | The run read a context key the cache key does not hold. The signal names it | Cover it with `vary:`, declare it in `neutral_keys:` or stop reading it |
| `:context_written` | The run wrote a covered key, or one it had read | |
| `:policy_consulted` | A `:public` answer, and an authorization policy was consulted | Declare it `:viewer`, or bypass the rule |
| `:cost_unknown` | A Points limiter guards the query and the run recorded no cost | |
| `:run_too_long` | The run ended more than `max_ttl` after its lookup | |
| `:too_large` | The sealed entry is above `max_entry_bytes` | |
| `:write_refused` | The store refused the write: a purge or a reset landed meanwhile, or the entry is above the store's `max_bytes` | |
| `:store_failed` | The store raised on a lookup or write | `on_store_error:` |

An entry that is found but not served is a miss with `:cache_entry_rejected` and one of `:format`, `:key`, `:decrypt`, `:expired`, `:epoch`, `:tags`, `:purged` or `:cost_unknown`.

### Signals

The signals go to the `sinks:` you gave `use`. Their data holds reasons, scopes and TTLs; never a key, a viewer, a variable, a document, an operation id or name, or a tag. See [Telemetry](telemetry.md).

| Signal | When | Data |
|---|---|---|
| `:cache_hit` | Answered from the store | `scope` |
| `:cache_stored` | A miss ran and was stored | `scope`, `ttl` |
| `:cache_skipped` | A query was not cacheable, or a miss was not stored | `reason`; `key` only for `:context_read` and `:context_written`, and only a name you gave it |
| `:cache_entry_rejected` | A stored entry failed a check | `reason` |
| `:cache_store_failed` | The store raised | `operation` (`:lookup`, `:write` or `:purge`), `error` (the error's class name) |
| `:cache_purged` | A purge succeeded | `kind` (`:all`, `:viewer`, `:tag` or `:type`), and `type` for `:type` |

## Guarantees and limits

**Read this first: the recorder is a tripwire, not a proof.** Every guarantee below is about inputs graphql-ruby can see. The recorder sees reads through the context's public methods, and the policy mark sees Authorization's consultations. Neither sees the database, the clock, `ENV`, `Current` attributes, `I18n.locale`, feature flags read from a global, memoization across requests, or the state of an object held in the context (`context[:current_user].role`). An answer that depends on any of them is cached under a key that does not hold it unless you put it in `vary:`. A `:public` field whose data is scoped by a thread-local tenant serves one tenant's data to another.

What the cache guarantees, for inputs it can see:

- **No hit without admission.** An answer is served only to a persisted operation that PersistedQueries and Versioning admitted, sent through `execute` or `multiplex`, in a multiplex without a mutation, and whose client the Points limiters charge.
- **No undeclared context key was read.** Every key read from the context's construction on, outside a neutral reader, is in the key or declared answer-neutral, and no covered or already-read key was written during the run.
- **A shared answer comes only from a run that consulted no policy,** under declarations that say every selected field is public. A user the policy refuses never gets another user's cached answer through Authorization.
- **A per-viewer answer is served only to the same principal** (class and id), only when `viewer:` is set. Anonymous requests share answers only under `anonymous: :shared`.
- **A purge is never undone by a run that started before it.** A store reset counts as a purge of everything, and a failed purge raises.
- **Store failures open to computing, never to serving.** A broken, slow, poisoned, foreign or reset entry is a miss. With an encoder, a forged or moved entry cannot be opened, and nothing in the store names a viewer, tag, variable or operation in clear.
- **A hit costs the client the Points the run cost.**

Never cached:

- Raw queries, including those run with `armory_allow_raw_query`, and queries PersistedQueries or Versioning refused.
- Mutations, and every query in a call that holds one; subscriptions, including their re-runs.
- Queries your own code builds (`GraphQL::Query.new` with `query.result`, `multiplex` with built queries), `Query::Partial` and `run_partials`.
- Requests with `warden:`, `static_validator:`, `root_value:`, `use_visibility_profile:` or `validate: false`.
- Introspection, documents with a custom directive that is not `cache_safe`, `@defer` and `@stream`.
- Responses with errors, with `data` that is nil or not JSON-native, or with response extensions other than the limiters'.
- A run a `rescue_from` handler answered.
- Requests whose context holds `armory_full_schema` or `current_ability`.

Limits:

- **Staleness up to the TTL, unless purged.** A revoked permission keeps serving the cached answer to that same viewer until it expires or `purge(viewer:)` runs; data someone hid keeps showing to other viewers. See [Purging](#purging).
- **A hit runs nothing.** No resolver side effects (audit logs in resolvers, analytics), no graphql-ruby tracing, no multiplex analyzer, no Authorization signal, no `Time` charge and no `Concurrency` slot. The cache's own signals stand in. A multiplex-wide analyzer sees only the misses.
- **A hit's `data` is deep-frozen.** An app that changes `result["data"]` after a hit raises `FrozenError`; a miss's data is mutable.
- **Timing.** A hit is faster than a miss. For a `:public` answer that shows someone asked the same question within the TTL; for a `:viewer` answer, only the viewer's own history.
- **Cache flooding.** Each distinct value of a declared variable is an entry, so someone can fill the store and evict other entries. The persisted operations, the declared variables, `max_entry_bytes` and the TTLs bound it; a Redis of its own keeps it from reaching other data.
- **No stampede protection.** N concurrent misses on one key run N times and each writes; every write is a valid answer.
- **Signed or expiring values in data** (pre-signed URLs, short-lived tokens): a cached answer serves them until its TTL, past their own expiry. Declare such fields `cache: false`, or give them a TTL below the shortest embedded expiry.
- **Tags do not know where data came from,** so `purge(type:)` is best effort. Declare custom tags for derived data.
- **Declared-context methods and overrides are your word.** `context_methods:`, `neutral_keys:`, `own_checks:` and `cache_safe` are listed by the audit, which does not read what your code does.
- **The walk is conservative:** `@skip` and `@include` branches both count, and an inherited field keeps its declaring class's declaration.
- **The audit's `ok?` covers only refusals through Authorization's chokepoints,** as above.
- **On graphql 2.4 with json 3.x,** a schema graphql-ruby cannot print runs uncached (`:schema_unprintable`).
- **`Execution::Next`** is supported from graphql 2.6.2, as for the other modules.
- **Redis durability.** See [Stores](#stores).
- **Cursors** from the encrypted cursor encoder never repeat across clients, so "next page" requests rarely hit.

## References

- Redis: [`WAIT`](https://redis.io/docs/latest/commands/wait/), which `purge_replicas:` uses, and [key eviction](https://redis.io/docs/latest/develop/reference/eviction/), which decides what a full cache loses.
- Eventide: [The Doctrine of Useful Objects](https://eventide-project.org/user-guide/useful-objects.html#the-doctrine-of-useful-objects), the pattern this gem follows: tests read what an object recorded instead of mocking it.
