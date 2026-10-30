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
armory id_refused {:reason=>:invalid}
armory operation_refused {:reason=>:unknown_operation}
armory denied {:type=>"Invoice", :action=>:read}
```

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

A `reason` has a handful of values, so it is safe as a metrics tag. `Notifications` needs ActiveSupport loaded: passing it without ActiveSupport raises `Telemetry::ConfigurationError` at boot, instead of silently reporting nothing.

### What to watch for

| You see | It usually means | What to do |
|---|---|---|
| `id_refused` with `reason: :invalid` rising | Someone is sending forged or tampered IDs, or a key rotation left clients with IDs made with a key you dropped | If it follows a deploy, check [Rotating keys](encrypted-ids.md#rotating-keys-and-migrating-from-base64). Otherwise it is probing: nothing leaked, but you can rate limit that client |
| `id_refused` with `reason: :not_found` | A record that does not exist, or that is outside the client's scope. The signal is the same for both, as the client's answer is | A few are normal. A burst from one client walking IDs is an enumeration attempt |
| `operation_refused` with `reason: :unknown_operation` after a deploy | A client build whose operations are not in the manifest you ship | Deploy the manifest before, or with, the client |
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

Rate limiting has no sinks. It records on every query, in the query's context, what it charged and what remains: `context[:rate_limit_points]` and `context[:rate_limit_concurrency]`, which carry `limited: true` for the queries it refused or, in soft mode, would have refused. See [Rolling it out](rate-limiting.md#rolling-it-out) and [Showing clients their budget](rate-limiting.md#showing-clients-their-budget). Send those to the same place as the signals above.

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

telemetry.recorded           # => [[:id_refused, { reason: :invalid }]]
telemetry.recorded?(:id_refused) # => true
```

Through `use`, a sink that collects is enough:

```ruby
seen = []
use GraphQL::Armory::PersistedQueries, store: store, sinks: [->(signal, data) { seen << [signal, data] }]
```

## Reference

- `sinks:` is an option of `use GraphQL::Armory::Authorization`, `use GraphQL::Armory::IDs` and `use GraphQL::Armory::PersistedQueries`. An Array of callables taking `(signal, data)`, called in order; default `[]`.
- `Telemetry.new(sinks: [])`, `Telemetry.build(sinks: [])`, `telemetry.record(signal, **data)` (answers nil).
- `Telemetry::Notifications`: a sink that calls `ActiveSupport::Notifications.instrument("<signal>.graphql_armory", data)`. `Notifications.available?` tells whether ActiveSupport::Notifications is loaded.
- `Telemetry::Substitute`: `record`, `recorded` (an Array of `[signal, data]`), `recorded?(signal)`, and `fail_with(error)` / `recover` to make `record` raise, as a broken sink would.
- `Telemetry::ConfigurationError`, raised at boot when `sinks:` is not an Array of callables, or a sink reports `available?` as false.
- `Authorization::Telemetry` is the same class as `Telemetry`.

## Guarantees and limits

- **Sinks run inline**, in the request's thread, in the order given. A slow sink slows every request: increment a counter or enqueue, do not call a remote service.
- **A sink that raises raises.** The error reaches the request and the request fails with it; nothing is let through because of it. If you would rather a broken metrics client never fail a request, rescue inside your sink.
- **One request can record many signals**, one per decision (a list of invoices is several), and each query of a batch records its own.
- **Signals are not a security log by themselves.** They tell you what the gem decided; who asked comes from your request context.
- Names and reasons are part of the public API, but the gem is in prerelease: they may change before 1.0, and the CHANGELOG says so when they do.
- Rate limiting reports through the query context, not through sinks.

## References

- Rails guides: [Active Support Instrumentation](https://guides.rubyonrails.org/active_support_instrumentation.html), and the API of [`ActiveSupport::Notifications`](https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html).
- OWASP: [Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html) (what to log and what to leave out) and [Log Injection](https://owasp.org/www-community/attacks/Log_Injection).
- Eventide: [The Doctrine of Useful Objects](https://eventide-project.org/user-guide/useful-objects.html#the-doctrine-of-useful-objects), the pattern this gem follows: tests read what an object recorded instead of mocking it.
