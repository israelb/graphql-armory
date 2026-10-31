# Telemetry

Know what the gem allowed, refused and ran, without writing anything a client chose into your logs.

## The problem

A guard that works in silence is hard to operate:

- After a new policy ships, did it start denying real users?
- Is someone sending forged IDs, or did a key rotation leave clients with IDs that no longer decode?
- Is a client build missing from the persisted query manifest, and how much raw traffic is left before you can turn on `strict: true`?

The gem answers all of these with the same response, "not found" or a validation error, on purpose: a client must not learn why it was refused. That is right for the client and blind for you.

Logging the request is not the fix. An ID, an operation id or a query is text an attacker chooses, and writing it to a log ([log injection](https://owasp.org/www-community/attacks/Log_Injection)) or a metrics label (unbounded cardinality) turns one probe into a problem for your operations.

## The solution

Each module records **signals**: a short name and a small hash with a *reason*, never a value the client sent. You choose where they go by passing **sinks**, any callable that takes `(signal, data)`:

```ruby
use GraphQL::Armory::IDs, sinks: [->(signal, data) { Rails.logger.info("armory #{signal} #{data}") }]
```

It is the same mechanism in authorization, encrypted IDs and persisted queries, so one sink can serve all three. A built-in sink, `Telemetry::Notifications`, reports to `ActiveSupport::Notifications`, which is where Rails apps already send logs and metrics from.

## How to use it

### A sink for every module

```ruby
class AppSchema < GraphQL::Schema
  armory_log = ->(signal, data) { Rails.logger.info("armory #{signal} #{data}") }

  use GraphQL::Armory::Authorization, adapter: :pundit, sinks: [armory_log]
  use GraphQL::Armory::IDs, sinks: [armory_log]
  use GraphQL::Armory::PersistedQueries, store: PERSISTED_QUERIES, sinks: [armory_log]
end
```

```
armory id_refused {reason: :invalid}
armory operation_refused {reason: :unknown_operation}
armory denied {type: "Invoice", action: :read}
```

(Ruby before 3.4 prints a hash as `{:reason=>:invalid}`.)

### With ActiveSupport::Notifications

```ruby
use GraphQL::Armory::IDs, sinks: [GraphQL::Armory::Telemetry::Notifications]
```

Every signal becomes an event named `<signal>.graphql_armory`, with the signal's data as payload. Subscribe to the ones you care about, or to all of them:

```ruby
# config/initializers/armory.rb
ActiveSupport::Notifications.subscribe("id_refused.graphql_armory") do |_name, _start, _finish, _id, payload|
  Metrics.increment("graphql.id_refused", tags: ["reason:#{payload[:reason]}"])
end

ActiveSupport::Notifications.subscribe(/\.graphql_armory\z/) do |name, _start, _finish, _id, payload|
  Rails.logger.info("#{name} #{payload}")
end
```

A `reason` has a handful of values, so it is safe as a metrics tag. `Notifications` needs ActiveSupport loaded: passing it without ActiveSupport raises `Telemetry::ConfigurationError` at boot, instead of silently reporting nothing. A Rails app has ActiveSupport fully loaded; outside Rails, `require "active_support"` before `require "active_support/notifications"`, as the latter alone is not enough in recent versions.

### With Datadog

A sink is any callable, so a metrics client plugs in directly. With [DogStatsD](https://docs.datadoghq.com/metrics/dogstatsd_metrics_submission/?tab=ruby), every signal becomes a counter and the signal's data becomes its tags:

```ruby
# Gemfile: gem "dogstatsd-ruby"
require "datadog/statsd"

STATSD = Datadog::Statsd.new("localhost", 8125)

datadog = lambda do |signal, data|
  STATSD.increment("graphql_armory.#{signal}", tags: data.map { |key, value| "#{key}:#{value}" })
end

class AppSchema < GraphQL::Schema
  use GraphQL::Armory::Authorization, adapter: :pundit, sinks: [datadog]
  use GraphQL::Armory::IDs, sinks: [datadog]
  use GraphQL::Armory::PersistedQueries, store: PERSISTED_QUERIES, sinks: [datadog]
end
```

In Datadog you get metrics such as `graphql_armory.id_refused` with the tag `reason:invalid`, or `graphql_armory.denied` with `type:Invoice` and `action:read`. Graph them, and build a monitor on the ones that should stay near zero (`id_refused` with `reason:invalid`, `operation_refused` with `reason:unknown_operation`). The tags are safe because they hold reasons, type names and actions: few values, none chosen by a client, so they do not inflate your metrics' cardinality.

If you already use `ActiveSupport::Notifications`, subscribe once and send from there instead, so the sink stays out of the schema:

```ruby
ActiveSupport::Notifications.subscribe(/\.graphql_armory\z/) do |name, _start, _finish, _id, payload|
  STATSD.increment("graphql_armory.#{name.delete_suffix(".graphql_armory")}", tags: payload.map { |key, value| "#{key}:#{value}" })
end
```

The gem does not depend on Datadog or on any other backend. The same shape works for StatsD, Prometheus, OpenTelemetry or whatever your team uses: write the callable that turns `(signal, data)` into one call of that client. The example above follows Datadog's documented `increment(name, tags:)`; it has not been run against a live agent.

### Who asked

A sink that requires three arguments also receives the query's context, so it can read who was refused:

```ruby
count_probes = lambda do |signal, data, context|
  next unless signal == :operation_refused && data[:reason] == :raw_query

  Strikes.add(context[:client_ip])
end
```

The context is whatever the query was given: read it with `[]`, and do not change it. It is empty when the query has none. A sink that takes two arguments, or `*arguments`, never receives it, so a sink that logs what it gets does not start logging tokens. What you read from the context is yours to keep out of logs.

### What to watch for

| You see | It usually means | What to do |
|---|---|---|
| `id_refused` with `reason: :invalid` rising | Someone is sending forged or tampered IDs, or a key rotation left clients with IDs made with a key you dropped | If it follows a deploy, check [Rotating keys](encrypted-ids.md#rotating-keys-and-migrating-from-base64). Otherwise it is probing: nothing leaked, but you can rate limit that client |
| `id_refused` with `reason: :not_found` | A record that does not exist, or that is outside the client's scope. The signal is the same for both, as the client's answer is | A few are normal. A burst from one client walking IDs is an enumeration attempt |
| `operation_refused` with `reason: :unknown_operation` after a deploy | A client build whose operations are not in the manifest you ship | Deploy the manifest before, or with, the client |
| `operation_refused` with `reason: :raw_query` from one client | A client sending raw queries to a strict endpoint: a probe, or a client not migrated yet. Strict mode refuses before validating, so a detector that counts validation errors does not see it | Count it as a strike. See [Counting probes in strict mode](persisted-queries.md#counting-probes-in-strict-mode) |
| `raw_query_run` while you are in `strict: false` | Traffic that does not use persisted queries yet | When it reaches zero, turn on `strict: true` |
| `denied` rising for one `type` | A new or changed policy for that type | Compare with the release; the [audit](authorization.md#the-audit) lists the types and actions the rules cover |

## Signals

### Authorization

| Signal | When | Data |
|---|---|---|
| `:allowed` | The policy or ability said yes | `type`, `action` |
| `:denied` | It said no, nil or anything that is not a clear yes | `type`, `action` |
| `:bypassed` | The rule is `authorize :none, reason: "..."` | `type` (not on lists), `reason` |
| `:scoped` | A list or lookup went through the user's scope | `action` |

`type` is the Ruby class name of the object, `action` the rule's action. Record attributes are never included.

### Encrypted IDs

| Signal | When | Data |
|---|---|---|
| `:id_resolved` | An ID was honoured and its record found | `type` (GraphQL type name) |
| `:id_refused` | An ID was not honoured. The client gets `nil` in every case | `reason`, and `type` for `:not_found` |

The reasons of `:id_refused`:

| Reason | The ID |
|---|---|
| `:invalid` | Did not decrypt: forged, tampered, made with another key or tag, or garbage |
| `:malformed` | Decrypted, but is not `Type/key` |
| `:unknown_type` | Names a type the schema does not have, that is not visible to this client, or that does not implement `Node` |
| `:not_found` | Names a real type, but the record is missing or outside the client's scope. One reason for both, as the client cannot tell them apart either |

### Persisted queries

| Signal | When | Data |
|---|---|---|
| `:operation_persisted` | A request ran the stored operation its id names | none |
| `:operation_refused` | A request was refused | `reason`: `:unknown_operation`, `:mismatch` (the id and the query sent with it differ) or `:raw_query` (strict mode, no allow flag) |
| `:raw_query_run` | A raw query ran because the plugin is not strict | none |
| `:raw_query_allowed` | A raw query ran in strict mode because the context holds `armory_allow_raw_query: true` | none |

`:raw_query_allowed` is your audit trail of who uses the escape hatch (staff, development).

### Rate limiting

Rate limiting takes `sinks:` for one signal, when its store fails:

| Signal | When | Data |
|---|---|---|
| `:rate_limit_store_failed` | The store raised, so the query ran without a limit | `limiter`: `:points`, `:concurrency` or `:time`; `error`: the error's class name |

Everything else it records on every query, in the query's context. It records on every query, in the query's context, what it charged and what remains: `context[:rate_limit_points]`, `context[:rate_limit_concurrency]` and `context[:rate_limit_time]`, which carry `limited: true` for the queries it refused or, in soft mode, would have refused. See [Rolling it out](rate-limiting.md#rolling-it-out) and [Showing clients their budget](rate-limiting.md#showing-clients-their-budget). Send those to the same place as the signals above.

## What telemetry does not cover

Signals are counters of the gem's decisions. They are not a replacement for these:

- **Traces.** A signal is a point event, not a span. In Datadog APM (or any tracer) a refused ID does not appear as a span of its own; it shows in the trace of the request that carried it, as the normal "not found" answer. If you want it on the trace, have your sink add a tag to the active span with your tracer's API.
- **Who asked, in the signal.** A signal says `id_refused`, not which user or IP. A sink that takes three arguments receives the query's context and can read them from it: see [Who asked](#who-asked).
- **Rate limiting's decisions.** Its sinks hear only about a failing store: what it charged is in the query's context. It records in the query's context. Send `context[:rate_limit_points]`, `context[:rate_limit_concurrency]` and `context[:rate_limit_time]` from your controller, to the same client. They hold the rate limit `key:` (a user id or an IP): send them somewhere that may hold personal data, or leave the key out.
- **Slow or failing requests.** The gem records its decisions. Latency, errors and throughput of your GraphQL endpoint come from your APM or from graphql-ruby's own tracing.
- **Anything that did not reach the gem.** A request rejected before GraphQL runs (a web application firewall, a body size limit, a parse error) never produces a signal.
- **A guarantee of delivery.** Sinks run in the request and report nothing if the process dies first. Counters sent to StatsD are best effort by design.
- **History.** The gem keeps nothing: the signals are as durable as the place you send them.

## What a signal never holds

A signal has a reason and, where it helps, the name of a type or an action. It **never** holds:

- an ID, an operation id or a query, which the client chose;
- a rate limit key, a user id or a record attribute;
- the exception message of a decryption failure.

For IDs and persisted queries a test pins it (`spec/security/telemetry_signals_spec.rb`): a forged ID and an attacker-chosen operation id are sent, and neither appears in anything recorded. Keep it that way in your own sinks: add the request id or the user from *your* request context if you need them, as your logger already does.

## Testing

`Telemetry::Substitute` keeps what was recorded, so a test reads it instead of mocking:

```ruby
telemetry = GraphQL::Armory::Telemetry::Substitute.new
lookup = GraphQL::Armory::IDs::Lookup.new(
  encoder: GraphQL::Armory::IDs::Controls::Encoder.example,
  telemetry: telemetry
)

lookup.object_for("forged", context)

telemetry.recorded               # => [[:id_refused, { reason: :invalid }]]
telemetry.recorded?(:id_refused) # => true
```

Through `use`, a sink that collects is enough:

```ruby
seen = []
use GraphQL::Armory::PersistedQueries, store: store, sinks: [->(signal, data) { seen << [signal, data] }]
```

## Reference

- `sinks:` is an option of `use GraphQL::Armory::Authorization`, `use GraphQL::Armory::IDs`, `use GraphQL::Armory::PersistedQueries` and the rate limiters. An Array of callables taking `(signal, data)` or `(signal, data, context)`, called in order; default `[]`.
- `on_sink_error:` is an option of the same modules except the rate limiters. A callable `(error, signal)` called when a sink raises; by default it warns with the signal and the error's class. Raise from it to fail the request closed.
- `Telemetry.new(sinks: [], on_sink_error: nil)`, `Telemetry.build(sinks: [], on_sink_error: nil)`, `telemetry.record(signal, context: nil, **data)` (answers nil; `data` reaches the sinks frozen).
- `Telemetry::Notifications`: a sink that calls `ActiveSupport::Notifications.instrument("<signal>.graphql_armory", data)`. `Notifications.available?` tells whether ActiveSupport::Notifications is loaded.
- `Telemetry::Substitute`: `record`, `recorded` (an Array of `[signal, data]`), `contexts`, `recorded?(signal)`, and `fail_with(error)` / `recover` to make `record` raise, as a broken sink would.
- `Telemetry::ConfigurationError`, raised at boot when `sinks:` is not an Array of callables, or a sink reports `available?` as false. Its message names the class of the offending value and never prints the value: a metrics client holds its API key.
- `Authorization::Telemetry` is the same class as `Telemetry`.

## Guarantees and limits

- **Sinks run inline**, in the request's thread, in the order given. A slow sink slows every request: increment a counter or enqueue, do not call a remote service.
- **A sink that raises does not touch the request.** The gem's decision stands, the next sink runs, and `on_sink_error:` is called. By default that prints the signal and the error's class, never its message, which may hold a credential, once per failure: one request can print many. If the record must exist before the data is served (an audit log), raise from `on_sink_error:` to fail the request closed. On a rate limiter a sink always only warns: use `on_store_error:` to act on a failing store.
- **Every sink gets the same frozen data.** The Hash and its String values are frozen, so a sink cannot change what the next one sees: trying raises `FrozenError`. The signals carry only Symbols and Strings today. `Notifications` makes one unfrozen copy per signal, which ActiveSupport passes to every subscriber: a subscriber that changes its payload changes it for the next subscriber.
- **One request can record many signals**, one per decision (a list of invoices is several), and each query of a batch records its own.
- **Signals are not a security log by themselves.** They tell you what the gem decided; who asked comes from your request context.
- Names and reasons are part of the public API, but the gem is in prerelease: they may change before 1.0, and the CHANGELOG says so when they do.
- Rate limiting reports its charges through the query context; its sinks hear only about a failing store.

## References

- Rails guides: [Active Support Instrumentation](https://guides.rubyonrails.org/active_support_instrumentation.html), and the API of [`ActiveSupport::Notifications`](https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html).
- OWASP: [Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) (what to log and what to leave out) and [Log Injection](https://owasp.org/www-community/attacks/Log_Injection).
- Eventide: [The Doctrine of Useful Objects](https://eventide-project.org/user-guide/useful-objects.html#the-doctrine-of-useful-objects), the pattern this gem follows: tests read what an object recorded instead of mocking it.
