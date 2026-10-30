# Rate limiting

Each client gets a budget of work per minute, measured in what its queries cost, not in how many requests it sends.

## The problem

A REST API can limit requests per minute because requests cost roughly the same. GraphQL requests do not:

```graphql
{ me { name } }                                                   # almost free
{ invoices(first: 1000) { lines { product { reviews { author { name } } } } } }  # seconds of work
```

A limit of 100 requests per minute lets a client send 100 of the second kind, by mistake or on purpose, and keep your servers busy while everyone else waits. Counting requests does not stop it.

## The solution

`GraphQL::Armory::RateLimits::Points` charges every query its **complexity**: the score graphql-ruby already computes from the fields a query asks for, before running it. Each client has a bucket of points that refills over a window:

- **Refused before running.** A query that costs more than the client has left is refused before any field resolves, so it costs your servers nothing. It is not charged either.
- **Predictable for clients.** The refusal says what the query cost, what remains and when to retry, so a client can adapt.
- **Per client.** Each client key (a user, an API token, an IP) has its own bucket; you can give each key its own limit.
- **Safe to roll out.** Soft mode, the default, charges and records but refuses nothing, so you can watch real traffic before turning it on.

`GraphQL::Armory::RateLimits::Concurrency` adds a second rule: at most N operations running at the same time per client ([Operations at the same time](#operations-at-the-same-time)). Both keep their state in a store: `MemoryStore` for tests and one process, `RedisStore` for production ([Sharing limits between processes](#sharing-limits-between-processes)). Planned: a layer that measures processing time (see [Planned](#planned)).

## How to use it

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::RateLimits::Points,
    store: GraphQL::Armory::RateLimits::MemoryStore.new,
    limit: 1_000,   # points
    window: 60,     # seconds: the bucket refills 1,000 points every minute
    soft: false     # refuse; leave it out (soft mode) while you measure
end
```

Name the client in the context:

```ruby
context = {
  current_user: current_user,
  rate_limit_key: current_user ? "user:#{current_user.id}" : "ip:#{request.remote_ip}"
}
AppSchema.execute(params[:query], variables: params[:variables], context: context)
```

A query without a key raises `RateLimits::ConfigurationError`, so a forgotten controller is caught at once instead of running unlimited. To build the key another way, pass `key: ->(query) { ... }`.

### What a query costs

graphql-ruby scores a query before running it:

- Every field costs **1 point**, unless you give it another score.
- Inside a connection, the fields selected under each node cost **page size × their points** (`first:` or `last:`, variables included).
- Fractional complexities are charged in whole points, rounded up.

A worked example:

```graphql
query {
  viewer {                            # 1
    invoices(first: 50) {             # 1
      nodes {                         # 1
        number                        # 50 invoices × 1
        lines(first: 20) {            # 50 × 1
          nodes {                     # 50 × 1
            product                   # 50 × 20 lines × 1
            comments(first: 10) {     # 50 × 20 × 1
              nodes {                 # 50 × 20 × 1
                body                  # 50 × 20 × 10 comments × 1
              }
            }
          }
        }
      }
    }
    followers(first: 10) {            # 1
      nodes {                         # 1
        name                          # 10 followers × 1
      }
    }
  }
}
```

Calculation:

```
3                                   = viewer, invoices, nodes
+ 50 × 3                 =    150   = number, lines, nodes, for each invoice
+ 50 × 20 × 3            =  3,000   = product, comments, nodes, for each line
+ 50 × 20 × 10 × 1       = 10,000   = body, for each comment
+ 2 + 10 × 1             =     12   = followers, nodes, and name for each follower
                         = 13,165 points
```

With `limit: 1_000` this query can never run; asking for `invoices(first: 5)` instead costs about a tenth. The numbers were measured with graphql-ruby's own analysis, so they are exactly what the limiter charges.

Give expensive fields a higher score where you define them, so their cost reflects real work:

```ruby
field :report, ReportType, null: false, complexity: 40      # 40 points instead of 1
field :create_invoice, mutation: Mutations::CreateInvoice, complexity: 10  # 10 points plus its selections
```

Three settings make the scores fair. Large public APIs (GitHub, Shopify, see [References](#references)) do the same:

- **Paginate every list.** A plain list field (`[Invoice]`) costs its fields **once**, however many items it returns, so 10,000 invoices cost like one. Use connections for anything that can grow. A connection asked for without `first:` or `last:` is sized by the schema's `default_page_size`, or else by `default_max_page_size`. If neither is set, graphql-ruby raises `GraphQL::Error` while scoring the query (a server error, not a refusal), so set one of them. GitHub goes further and requires `first:` or `last:` on every connection.
- **Cap a single query.** graphql-ruby's `max_complexity 1_000` refuses any query above that score, whatever the client's budget. Shopify caps single queries at 1,000 points.
- **Make writes cost more.** Give mutations a higher `complexity:`: `complexity: 10` charges 10 points for the mutation field itself, plus the fields it selects. Shopify charges 10 points per mutation by default.

See graphql-ruby's [complexity and depth guide](https://graphql-ruby.org/queries/complexity_and_depth) for computed costs.

### When a client runs out

The response holds only the refusal:

```json
{
  "errors": [{
    "message": "Rate limit exceeded: this query costs 40 points and 20 remain (1000 every 60 seconds). Retry in 2 seconds.",
    "extensions": { "code": "RATE_LIMITED", "cost": 40, "remaining": 20, "retryAfter": 2 }
  }]
}
```

A query that costs more than the whole limit can never run, and says so: `this query costs 1200 points and the limit is 1000 every 60 seconds, so it can never run.` Its extensions hold `cost` and `limit`.

### Showing clients their budget

A client that only learns its budget when it is refused cannot pace itself. GitHub sends the budget in headers on every response; Shopify puts it in the response's `extensions`. You can do either, or both.

In the response, with `extensions: true`:

```ruby
use GraphQL::Armory::RateLimits::Points, store: store, limit: 1_000, window: 60, soft: false, extensions: true
```

```json
{
  "data": { "report": { "total": 120 } },
  "extensions": { "rateLimit": { "cost": 40, "limit": 1000, "remaining": 960, "resetIn": 3 } }
}
```

`resetIn` is the number of seconds until the bucket is full again. It is on refused responses too, and absent for a client with no limit. It is off by default, so responses do not change until you turn it on.

In HTTP headers, from your controller:

```ruby
result = AppSchema.execute(params[:query], variables: params[:variables], context: context)
response.headers.merge!(GraphQL::Armory::RateLimits::Points.headers(result))
render json: result
```

That sets `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset` (seconds until the bucket is full), or nothing when the query had no limit. It works whether or not `extensions:` is on, and reads each query's own budget, also in a multiplex. The `rateLimit` key of the response extensions belongs to the limiter: do not write it yourself.

### Different limits per client

```ruby
use GraphQL::Armory::RateLimits::Points, store: store, window: 60,
  limit: ->(key, query) { key.start_with?("partner:") ? 10_000 : 1_000 }
```

The callable answers a positive Integer, or nil for no limit (for example an internal service). Anything else raises.

### Operations at the same time

Points limit how much work a client asks for per minute. They do not stop a client that sends 30 cheap requests at once and occupies every server process while they run: GitHub, for one, also caps concurrent requests. Add `Concurrency` next to `Points`:

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::RateLimits::Concurrency,
    store: store,      # the same store as Points
    limit: 5,          # operations running at once per client
    soft: false
end
```

It uses the same `rate_limit_key`. Before an operation runs it takes one of the client's slots; when the operation ends, it gives the slot back, even if the operation raised or another analyzer refused it. A client whose slots are all taken is refused before any field resolves:

```json
{
  "errors": [{
    "message": "Too many operations at the same time: 5 are already running for this client (limit 5). Retry when one finishes.",
    "extensions": { "code": "RATE_LIMITED", "limit": 5, "active": 5 }
  }]
}
```

A process that crashes never gives its slots back, so each slot expires after `stale_after:` seconds (60 by default). Set it above your longest request timeout. Soft mode, per-key limits (`limit: ->(key, query) { ... }`) and `on_store_error:` work as for `Points`; what happened is in `result.context[:rate_limit_concurrency]` (`{ key:, limit:, active:, soft:, limited: }`).

### Rolling it out

1. Install it in soft mode (leave out `soft:`). Queries run as before; each one records what it cost.
2. Send what it recorded to your metrics: `result.context[:rate_limit_points]` is `{ key:, cost:, limit:, remaining:, window:, soft:, limited: }`, and `limited: true` marks the queries that would have been refused.
3. When the limits fit your traffic, set `soft: false`.

### Sharing limits between processes

`MemoryStore` keeps buckets in one process: with four Puma workers on two servers, a client gets the limit eight times over, and a restart refills every bucket. In production use `RedisStore`, which keeps them in Redis, shared by every process:

```ruby
# Gemfile: gem "redis"
RATE_LIMIT_STORE = GraphQL::Armory::RateLimits::RedisStore.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")))

class AppSchema < GraphQL::Schema
  use GraphQL::Armory::RateLimits::Points, store: RATE_LIMIT_STORE, limit: 1_000, window: 60, soft: false
  use GraphQL::Armory::RateLimits::Concurrency, store: RATE_LIMIT_STORE, limit: 5, soft: false
end
```

- **Atomic.** Each charge, slot taken and slot released is one Lua script, so two requests of the same client never both spend the last points.
- **One clock.** The time comes from Redis (`TIME`), not from each server, so servers whose clocks drift still agree on when a bucket refills.
- **Small.** A client costs two keys, `graphql-armory:rate-limits:points:<key>` and `...:slots:<key>`; both expire once they no longer matter (a window, or `stale_after`, after the last use). Pass `prefix:` to share one Redis with other apps.
- **Fails open.** When Redis is down or slow, the client raises, the query runs, and `on_store_error` is called: make that hook alert. Set the client's timeouts (for example `Redis.new(url: ..., timeout: 0.2)`) so a slow Redis cannot slow every request.

The gem does not depend on the redis gem: add it to your Gemfile. A single `Redis` client is safe to share between threads.

### Testing your limits

`RateLimits::Store::Substitute` is a `MemoryStore` on a clock your test moves, that records its calls and fails when told, so specs need no mocks and no sleeping:

```ruby
store = GraphQL::Armory::RateLimits::Store::Substitute.new
schema = Class.new(AppSchema) { use GraphQL::Armory::RateLimits::Points, store: store, limit: 100, window: 60, soft: false }

store.now += 30                                     # half a window later
store.fail_with(IOError.new("down"), on: :take)     # the next charges raise, as a broken Redis would
store.answer(:take, [0, 0])                         # an answer no real store gives
store.calls                                         # [[:take, "user:1", { cost: 40, limit: 100, window: 60, force: false }], ...]
```

`occupy(key)` holds a slot for an operation running elsewhere and `held(key)` counts the slots held. `RateLimits::Controls::Query.example`, `Root.example` and `Context.example` are a small schema and context to test against. `Points.new` and `Concurrency.new`, with nothing wired, refuse every query (`Store::Null`); `Points.build(...)` and `Concurrency.build(...)` take the same settings as `use`.

## Reference

`use GraphQL::Armory::RateLimits::Points, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil, extensions: false`

- `store:` answers `take(key, cost:, limit:, window:, force:)` with `[taken, remaining]`. `MemoryStore.new(clock: ...)` keeps buckets in the process; `RedisStore` shares them (below).
- `limit:` a positive Integer, or a callable `(key, query)` answering a positive Integer or nil.
- `window:` positive seconds over which `limit` points refill, continuously.
- `soft:` `true` (default) charges and records without refusing; `false` refuses.
- `key:` a callable `(query)` answering the client key; by default `context[:rate_limit_key]`. It must be a non-empty String.
- `on_store_error:` a callable `(error, query)` called when the store raises; the query then runs (fails open). By default it warns.
- `extensions:` `true` adds `"rateLimit" => { cost, limit, remaining, resetIn }` to every response of a limited client; `false` (default) leaves responses unchanged.
- `Points.headers(result)` answers the `RateLimit-*` headers for a result, or `{}`.
- Instrumentation: `context[:rate_limit_points]`.

`use GraphQL::Armory::RateLimits::Concurrency, store:, limit:, stale_after: 60, soft: true, key: nil, on_store_error: nil`

- `store:` answers `acquire(key, token:, limit:, ttl:, force:)` with `[acquired, active]` and `release(key, token:)`. `MemoryStore` does both.
- `limit:` operations at once per client: a positive Integer, or a callable `(key, query)` answering a positive Integer or nil.
- `stale_after:` positive seconds after which a slot that was never released expires.
- `soft:`, `key:` and `on_store_error:` as for `Points`. When the store raises on release, `on_store_error` is called and the slot expires after `stale_after`.
- Instrumentation: `context[:rate_limit_concurrency]`.

`GraphQL::Armory::RateLimits::RedisStore.new(redis:, prefix: "graphql-armory:rate-limits:", clock: nil)`

- `redis:` a redis-rb client (>= 4.8), or anything answering `eval(script, keys:, argv:)` and `evalsha(sha, keys:, argv:)` the same way. Needs Redis 5 or later. Works with Redis Cluster: each script touches one key.
- `prefix:` a non-empty String put before every key.
- `clock:` nil (default) reads Redis's clock; a callable answering seconds replaces it, for tests.

Invalid settings raise `RateLimits::ConfigurationError` at boot.

## Guarantees and limits

- A query this limiter refuses resolves no field and is not charged. A query that fails validation is not charged. A query refused by another analyzer (`max_depth`, `max_complexity`) is still charged: graphql-ruby runs every analyzer.
- Each query in a multiplex is charged on its own.
- `Concurrency` takes one slot per query of a multiplex, and releases them all when the multiplex ends, even when the queries share one context hash. If a release fails, that slot expires after `stale_after`; the others are still released.
- A query run with its own trace (`context: { trace: ... }`) cannot be released by `Concurrency`, so it raises `ConfigurationError` instead of taking a slot.
- A resolver that runs another query for the same client (a nested `execute`) takes a second slot while the first is held.
- A subscription holds a slot only while its first result runs, not while it stays subscribed.
- When queries of a multiplex share one context hash, `context[:rate_limit_points]` and `context[:rate_limit_concurrency]` hold the last query's record: give each query its own context hash to read every record.
- The cost is graphql-ruby's estimate before running, not the time a query really takes: a field that is slow but scored 1 costs 1. Score expensive fields, and add the processing-time layer when it ships.
- Field scores are yours: graphql-ruby treats a negative or NaN complexity as 0, so such a field is free, like `complexity: 0`. A complexity that is nil or a String makes graphql-ruby raise before the limiter runs, so the query does not run.
- When the store fails, queries run unlimited and `on_store_error` is called. Choose that hook to alert. `RedisStore` also counts a bucket whose fields were changed into something that is not a number as a store failure, rather than reading it as full.
- `MemoryStore` keeps buckets and slots in one process and forgets them on restart: with several processes, each one gives a client the full limit. It keeps one entry per client key it has seen. Use `RedisStore` in production.

## Planned

- **Processing time, a second layer:** a budget of milliseconds per client per window, measured as queries run, for costs the complexity score does not see.

## References

The same technique, charging queries a calculated cost against a budget per client, is used by large public GraphQL APIs:

- GitHub: [Rate limits and query limits for the GraphQL API](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api): a points budget per hour, where connections' `first`/`last` drive the cost, and a `rateLimit` field showing what remains.
- Shopify: [GraphQL Admin API rate limits](https://shopify.dev/docs/apps/build/apis/graphql-admin/rate-limits): a calculated query cost against a bucket that refills continuously; Shopify also refunds the difference when the real cost is lower than the estimate.
- Cha et al., [A Principled Approach to GraphQL Query Cost Analysis](https://arxiv.org/abs/2009.05632) (ESEC/FSE 2020, IBM Research): estimating a query's cost statically, before running it, and why naive estimates over- or under-count.
- graphql-ruby: [Complexity and depth](https://graphql-ruby.org/queries/complexity_and_depth), the cost this limiter charges.
