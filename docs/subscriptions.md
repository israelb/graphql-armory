# Subscriptions over hosted pub/sub

Run graphql-ruby subscriptions over a hosted pub/sub service (Pusher, Ably, or anything with the same shape) without
letting one subscriber's update reach another, and without a provider SDK.

## The problem

graphql-ruby ships an abstract `GraphQL::Subscriptions` backend and an in-process ActionCable one. A backend for a
hosted service has to decide what to store, whose context an update runs with and who receives the result, and the
base class's defaults are unsafe for an app with more than one user:

- `trigger(..., context: { current_user: admin })` merges that context over every subscriber's own, so each
  subscriber's update runs as the trigger's caller (or under the trigger's API version).
- Topics are built by joining the field name and argument values with `":"`, unescaped: `room(id: "5:thread:9")` and
  `room(id: "5", thread: "9")` share a topic, and so do the scopes `1` and `"1"`.
- A subscriber whose `authorized?` check fails on an update gets an error and stays subscribed, so a user who lost
  access keeps a live subscription.
- A field marked `broadcastable: true` runs once and sends the first subscriber's answer to everyone on the topic,
  whoever they are.

On a hosted service there is more: the subscription id is the channel name, so anyone who learns it can listen
unless the channel is bound to its viewer; no provider tells you reliably when a client is gone; and each provider
has its own message size limit, from 10 KB on Pusher to 64 or 256 KiB on Ably.

## The solution

`GraphQL::Armory::Subscriptions` is a `GraphQL::Subscriptions` backend made of a provider-agnostic core, a store and
a transport.

- **Each delivery runs as its subscriber.** The core stores the subscription as a record sealed with your
  `Encoder`: the document, its variables, the viewer's id, the API version Versioning decided, the persisted
  operation id and only the context keys you list in `context_keys:`. On a trigger it rebuilds each subscriber's
  context from that record, reloads the viewer with your `viewer: { load: }`, and runs the document through your
  schema's query class, on the engine that created the subscription. Authorization, Versioning and
  PersistedQueries decide it like a request. The trigger's context is never merged: `trigger(..., context: {...})`
  raises.
- **A subscriber who loses access is unsubscribed.** If the update has no `data`, or its root field is null (a
  denied root with `on_unauthorized: :null`, the default, answers null without an error), the subscriber gets that
  last result with `more: false` and the subscription is deleted. A viewer that no longer loads ends the same way.
- **Topics cannot collide.** A topic is a keyed digest of a canonical JSON of the field, its arguments taken
  through their definitions (so `5` and `"5"` for an `ID` meet, an enum by Ruby value and by name meet, defaults are
  filled) and a type-tagged scope (`1` and `"1"` differ).
- **Nothing is broadcast.** Every subscriber is executed with its own context.
- **Channels are bound to their viewer.** The transport names a channel from the subscription id (and, on Ably, the
  viewer's digest). The core authorizes a channel only for the viewer that created it, compared in constant time,
  and only then does the transport sign the provider's auth answer. The id is built by the server; a client that sets
  `context[:subscription_id]` is refused.
- **Every subscription ends.** `max_lifetime:` is required. Provider webhooks (Pusher `channel_vacated`, Ably
  presence `leave`), verified in constant time, end one sooner.
- **Deliveries are not rate-charged.** A delivery is marked in `context.namespace(:armory)`, which a request cannot
  write, and RateLimits charges no budget for it, so someone who causes triggers cannot spend another user's budget.
  `max_complexity` and `max_depth` still apply, and caps bound the work: `max_per_viewer:`, `max_per_topic:` and
  `max_executions_per_trigger:`.

Transports declare their capabilities: whether they can bind a channel to a viewer, the largest message, the largest
batch, their webhooks and compression. With a `viewer:`, `use` refuses a transport that cannot bind channels.

## How to use it

```ruby
class AppSchema < GraphQL::Schema
  subscription Types::Subscription

  use GraphQL::Armory::Authorization, adapter: :pundit
  use GraphQL::Armory::Subscriptions,
    store: GraphQL::Armory::Subscriptions::RedisStore.build(redis: Redis.new, prefix: "app:{subscriptions}:"),
    transport: GraphQL::Armory::Subscriptions::Pusher.build(
      app_id: ENV["PUSHER_APP_ID"], key: ENV["PUSHER_KEY"], secret: ENV["PUSHER_SECRET"], cluster: "eu"
    ),
    encoder: AppEncoder,                          # an Encoder subclass: seals records, keys digests
    viewer: {
      dump: ->(context) { context[:current_user]&.to_gid&.to_s },
      load: ->(id, context) { context[:current_user] = GlobalID::Locator.locate(id) },
      sets: [:current_user]                       # the context keys load sets (a subscription_scope may use them)
    },
    context_keys: { tenant_id: "scopes every query to the subscriber's tenant" },
    max_lifetime: 24 * 3600
end
```

The subscribe request is an ordinary GraphQL request. Send the channel back so the client can listen:

```ruby
result = AppSchema.execute(query, variables:, context:)
channel = AppSchema.subscriptions.channel_for(result.query)
response.headers["X-Subscription-ID"] = channel if channel
```

Trigger from your code, with no context:

```ruby
AppSchema.subscriptions.trigger(:message_posted, { room_id: room.id }, message, scope: tenant.id)
AppSchema.subscriptions.trigger(:message_posted, { room_id: room.id }, message, version: "2025-01-01") # with Versioning default: :refuse
```

Mount the webhook endpoint and run cleanup periodically:

```ruby
mount GraphQL::Armory::Subscriptions::WebhookApp.new(AppSchema), at: "/graphql/webhooks"
AppSchema.subscriptions.cleanup   # from a periodic job
```

On the client, the MIT `graphql-ruby-client` links work unchanged: they read `X-Subscription-ID`, listen for the
`update` event and read `{ result | compressed_result, more }`.

### Pusher

```ruby
GraphQL::Armory::Subscriptions::Pusher.build(
  app_id: ENV["PUSHER_APP_ID"], key: ENV["PUSHER_KEY"], secret: ENV["PUSHER_SECRET"],
  cluster: "eu",          # or host: "soketi.internal:6001", scheme: "http" for a Pusher-compatible server
  prefix: "graphql",      # channels are private-<prefix>-<subscription id>
  compress: false         # true when the client decompresses compressed_result
)
```

Every subscription gets a private channel. `pusher-js` asks your auth endpoint for it:

```ruby
post "/pusher/auth" do
  auth = AppSchema.subscriptions.authorize_channel(
    channel: params[:channel_name], socket_id: params[:socket_id], context: current_context
  )
  auth ? render(json: auth) : head(:forbidden)
end
```

Build `current_context` exactly as your GraphQL endpoint does: the channel is authorized only when its viewer is the
requester. In the Pusher dashboard, enable the `channel_vacated` webhook and point it at the `WebhookApp`. On the
client use `PusherLink` (pass it `decompress` with `compress: true`).

Limits: 10 KB per event (the compressed form is measured when compression is on) and 10 events per publish. Pusher
sends `channel_vacated` about 3 seconds after the last client leaves and retries for 5 minutes.

### Ably

```ruby
GraphQL::Armory::Subscriptions::Ably.build(
  key: ENV.fetch("ABLY_KEY"),   # "<appId>.<keyId>:<secret>", with only the publish capability on <prefix>:*
  prefix: "graphql",
  max_payload_bytes: 65_536     # up to 262_144 on plans that allow it
)
```

Ably authorizes a connection, not a channel, so a channel is `<prefix>:<viewer digest>:<id>` and your token endpoint
answers a TokenRequest whose capability is the viewer's own channels only:

```ruby
post "/ably/auth" do
  token = AppSchema.subscriptions.authorize_viewer(context: current_context)
  token ? render(json: token) : head(:unauthorized)
end
```

```js
const ably = new Ably.Realtime({ authUrl: "/ably/auth", authMethod: "POST" })
const link = new AblyLink({ ably })
```

The browser never receives the key. Add a webhook integration for presence events on `<prefix>:*` pointing at the
`WebhookApp`: a presence `leave` on a subscription channel ends it.

Limits: 64 KiB per message (256 KiB on plans that allow it); a batch stays under Ably's 2 MiB request limit, which is
15 messages at 64 KiB. A leave arrives about 15 seconds late. A token lasts at most one hour.

### Stores

A store holds sealed records and indexes of topic and viewer digests, never a document, a variable or a viewer in
clear. `MemoryStore.new` keeps everything in one process: for tests, development and single-process servers.
`RedisStore.build(redis:, prefix:)` is for production: each operation is one Lua script, so the caps hold across
processes. Times are the caller's clock, so clock skew between your servers and Redis never decides whether a
subscription is live. Use a Redis with `noeviction` or `volatile-*`. On Redis Cluster the prefix needs a hash tag,
such as `"app:{subscriptions}:"`. Call `cleanup` periodically: it frees the expiry index.

### The audit

```ruby
GraphQL::Armory::Subscriptions::Audit.call(AppSchema)
```

It reports subscription fields marked `broadcastable: true` (ignored), anonymous mode, and every `context_keys:`
entry with its reason.

## Reference

`use GraphQL::Armory::Subscriptions, ...` (`Subscriptions.build(schema, ...)` answers the backend without installing
it; `Subscriptions.new` is inert: it stores, delivers and authorizes nothing).

| Option | Default | |
|---|---|---|
| `store:` | required | `MemoryStore` or `RedisStore`; `Store::Null` is refused |
| `transport:` | required | `Pusher`, `Ably` or your own; `Transport::Null` is refused |
| `encoder:` | required | an `Encoder` subclass |
| `max_lifetime:` | required | seconds a subscription lives at most |
| `viewer:` | | `{ dump: ->(context) { id String }, load: ->(id, context) { ... }, sets: [keys load sets] }` |
| `anonymous:`, `cap_key:` | | instead of `viewer:`: a reason no subscription depends on the viewer, and a callable answering what the per-client cap counts by (the client IP) |
| `context_keys:` | `{}` | `{ key: "reason" }`: the only context values stored and restored; values must round-trip through graphql-ruby's `Serialize`. `armory_version`, `operation_id`, `armory_allow_raw_query`, `visibility_profile` and `subscription_id` are reserved |
| `max_per_viewer:` | 100 | live subscriptions per viewer (or per `cap_key`) |
| `max_per_topic:` | 10_000 | live subscriptions per topic |
| `max_executions_per_trigger:` | 10_000 | subscribers executed per trigger; the rest are skipped and recorded |
| `on_delivery_error:` | `:record` | `:raise` raises after the whole topic was processed |
| `sinks:`, `on_sink_error:` | | [Telemetry](telemetry.md#subscriptions) |

`use` refuses: unknown options, `broadcast:`, `default_broadcastable:`, `validate_update:`, a viewer with a transport
that cannot bind channels, a Subscription class overriding `topic_for`, subscription arguments with `loads:` or
`prepare:`, and a `subscription_scope` key that is neither in `context_keys:` nor in `viewer: { sets: }`.

Methods on `AppSchema.subscriptions`: `trigger(event, args, object, scope: nil, version: nil)`, `channel_for(query)`,
`authorize_channel(channel:, socket_id:, context:)`, `authorize_viewer(context:)`, `webhook(env)`,
`cleanup(now: nil)`, `delete_subscription(id)`.

Error codes a client can read: `SUBSCRIPTION_LIMIT` (a cap), `SUBSCRIPTION_REFUSED` (anything else refused at
subscribe), and `RESULT_TOO_LARGE` in an update whose result does not fit the transport (the client should refetch).

## Guarantees and limits

Guaranteed:

1. A delivery runs with the subscriber's stored keys and reloaded viewer, never the trigger's context.
2. Different fields, arguments or scopes never share a topic.
3. A subscriber whose update has no data or a null root field is unsubscribed, at the next trigger.
4. A subscriber's result goes to that subscriber's channel only.
5. With a viewer, a channel is authorized only for the viewer that created it.
6. A client cannot choose its subscription id.
7. A stored record that was tampered with is deleted, never loaded.
8. Every subscription ends by `max_lifetime`.
9. A delivery never charges the subscriber's rate-limit budget.

Limits:

- Between a permission change and the next trigger, nothing is sent, but the subscription exists.
- A nested null (one hidden field) does not end a subscription; only the root field decides.
- Channel auth is as strong as your auth endpoint: it must build the context as your GraphQL endpoint does.
- Webhooks are lossy and late (about 3 seconds on Pusher, 15 on Ably); `max_lifetime` is what bounds a subscription.
- An expired subscription gets `{ more: false }` only if a trigger reaches it before `cleanup` removes it; after
  that it just stops.
- Triggers run in the calling process and synchronously: the request that triggers pays for every subscriber's
  execution, one execution per subscriber.
- A result larger than the transport's limit is replaced with `RESULT_TOO_LARGE`, never truncated.
- Subscription arguments with `loads:` or `prepare:` are not supported.
- Install it on the schema that executes: graphql-ruby shares one backend with child schemas.
- No ActionCable or AnyCable transport, no broadcast, no Ably end-to-end encryption.
