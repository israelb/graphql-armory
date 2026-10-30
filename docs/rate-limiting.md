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

Planned in the next releases: a limit on operations running at the same time per client, a Redis store shared between processes, and later a second layer that measures processing time (see [Planned](#planned)).

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

graphql-ruby scores a query by its fields: 1 point per field by default, and a connection multiplies the cost of the fields selected under each node by its page size (`first:` or `last:`, variables included). Fractional complexities are charged in whole points, rounded up. Give expensive fields a higher score where you define them:

```ruby
field :report, ReportType, null: false, complexity: 40
field :invoices, InvoiceType.connection_type, null: false  # the page size multiplies the cost of each node
```

See graphql-ruby's [complexity and depth guide](https://graphql-ruby.org/queries/complexity_and_depth) for computed costs. The better the scores reflect real work, the fairer the limit.

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

### Different limits per client

```ruby
use GraphQL::Armory::RateLimits::Points, store: store, window: 60,
  limit: ->(key, query) { key.start_with?("partner:") ? 10_000 : 1_000 }
```

The callable answers a positive Integer, or nil for no limit (for example an internal service). Anything else raises.

### Rolling it out

1. Install it in soft mode (leave out `soft:`). Queries run as before; each one records what it cost.
2. Send what it recorded to your metrics: `result.context[:rate_limit_points]` is `{ key:, cost:, limit:, remaining:, window:, soft:, limited: }`, and `limited: true` marks the queries that would have been refused.
3. When the limits fit your traffic, set `soft: false`.

## Reference

`use GraphQL::Armory::RateLimits::Points, store:, limit:, window: 60, soft: true, key: nil, on_store_error: nil`

- `store:` answers `take(key, cost:, limit:, window:, force:)` with `[taken, remaining]`. `MemoryStore.new(clock: ...)` keeps buckets in the process.
- `limit:` a positive Integer, or a callable `(key, query)` answering a positive Integer or nil.
- `window:` positive seconds over which `limit` points refill, continuously.
- `soft:` `true` (default) charges and records without refusing; `false` refuses.
- `key:` a callable `(query)` answering the client key; by default `context[:rate_limit_key]`. It must be a non-empty String.
- `on_store_error:` a callable `(error, query)` called when the store raises; the query then runs (fails open). By default it warns.
- Instrumentation: `context[:rate_limit_points]`.

Invalid settings raise `RateLimits::ConfigurationError` at boot.

## Guarantees and limits

- A query this limiter refuses resolves no field and is not charged. A query that fails validation is not charged. A query refused by another analyzer (`max_depth`, `max_complexity`) is still charged: graphql-ruby runs every analyzer.
- Each query in a multiplex is charged on its own.
- The cost is graphql-ruby's estimate before running, not the time a query really takes: a field that is slow but scored 1 costs 1. Score expensive fields, and add the processing-time layer when it ships.
- When the store fails, queries run unlimited and `on_store_error` is called. Choose that hook to alert.
- `MemoryStore` keeps buckets in one process and forgets them on restart: with several processes, each one gives a client the full limit. It keeps one entry per client key it has seen. Use a shared store in production (planned).

## Planned

- **Operations at the same time:** at most N queries running at once per client, released when each one ends.
- **A Redis store**, shared between processes and atomic.
- **Processing time, a second layer:** a budget of milliseconds per client per window, measured as queries run, for costs the complexity score does not see.
