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
- Field scores are yours: graphql-ruby treats a negative or NaN complexity as 0, so such a field is free, like `complexity: 0`. A complexity that is nil or a String makes graphql-ruby raise before the limiter runs, so the query does not run.
- When the store fails, queries run unlimited and `on_store_error` is called. Choose that hook to alert.
- `MemoryStore` keeps buckets in one process and forgets them on restart: with several processes, each one gives a client the full limit. It keeps one entry per client key it has seen. Use a shared store in production (planned).

## Planned

- **Operations at the same time:** at most N queries running at once per client, released when each one ends.
- **A Redis store**, shared between processes and atomic.
- **Processing time, a second layer:** a budget of milliseconds per client per window, measured as queries run, for costs the complexity score does not see.

## References

The same technique, charging queries a calculated cost against a budget per client, is used by large public GraphQL APIs:

- GitHub: [Rate limits and query limits for the GraphQL API](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api): a points budget per hour, where connections' `first`/`last` drive the cost, and a `rateLimit` field showing what remains.
- Shopify: [GraphQL Admin API rate limits](https://shopify.dev/docs/apps/build/apis/graphql-admin/rate-limits): a calculated query cost against a bucket that refills continuously; Shopify also refunds the difference when the real cost is lower than the estimate.
- Cha et al., [A Principled Approach to GraphQL Query Cost Analysis](https://arxiv.org/abs/2009.05632) (ESEC/FSE 2020, IBM Research): estimating a query's cost statically, before running it, and why naive estimates over- or under-count.
- graphql-ruby: [Complexity and depth](https://graphql-ruby.org/queries/complexity_and_depth), the cost this limiter charges.
