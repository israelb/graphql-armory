# Encrypted IDs and cursors

IDs and pagination cursors that clients can neither read, guess, nor forge.

## The problem

graphql-ruby's IDs and cursors are base64, which is an encoding, not encryption. A Relay ID such as `SW52b2ljZS80Mg` is `Invoice/42` to anyone who decodes it, and a cursor such as `MTA` is the position `10`. From them a client can:

- **Guess other IDs.** `Invoice/43`, `Invoice/44`… or `User/1`, `Admin/1`. Authorization still decides what it may read, but every guess costs you a lookup and probes your API.
- **Learn about your business.** Sequential IDs tell how many invoices or users you have and how fast they grow.
- **Edit cursors** to jump anywhere in a list or count its rows.

## The solution

`GraphQL::Armory::Encoder` encrypts and authenticates them with AES-256-GCM:

- **Opaque.** The ID of `Invoice/42` looks like `x0Tn…Qw`; nothing in it can be read.
- **Tamper-proof.** Change one character, use another key or another tag, and it does not decode. Every failure gives the same error, `Invalid ID or cursor`, without saying why.
- **Stable IDs.** The same object always has the same ID, so client caches (Apollo, Relay) keep working. Its nonce is derived from the ID, so two different IDs do not share one (a collision needs around 2^48 IDs).
- **Unpredictable cursors.** The same position gives a different cursor in every response.
- **IDs and cursors are not interchangeable.** Each uses its own derived key.

## How to use it

Generate a key once and keep it out of the code: `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`.

```ruby
class AppEncoder < GraphQL::Armory::Encoder
  key ENV.fetch("GRAPHQL_ARMORY_KEY")
end

class AppSchema < GraphQL::Schema
  cursor_encoder AppEncoder                      # every built-in connection now uses encrypted cursors

  def self.id_from_object(object, type, _context)
    AppEncoder.encode("#{type.graphql_name}/#{object.id}")
  end

  def self.object_from_id(id, _context)
    type_name, key = AppEncoder.decode(id).split("/", 2)
    # look the record up from type_name and key
  end
end
```

With the [authorization module](authorization.md), an ID the encoder refuses in a `loads:` argument is answered exactly like a missing record.

## Reference

| Declaration | Meaning |
|---|---|
| `key "..."` | Required. At least 32 bytes. Subkeys for IDs and cursors are derived from it with HKDF. |
| `tag "v1"` | Optional authenticated data. An ID made with another tag does not decode: use it to separate apps or environments sharing a key. |
| `codec MyCodec` | Optional. How the encrypted bytes become text; anything with `encode(bytes)` and `decode(text)`. Default: base64url without padding. Any error it raises while decoding becomes `InvalidError`. |

| Call | Returns |
|---|---|
| `encode(text)` | A stable, encrypted ID. |
| `encode(text, nonce: true)` | A cursor, different every time. |
| `decode(id)` / `decode(cursor, nonce: true)` | The text, or raises `GraphQL::Armory::Encoder::InvalidError` (a `GraphQL::ExecutionError`, so clients see `Invalid ID or cursor`). |

A subclass inherits `key`, `tag` and `codec`, and can override any of them. Passing `nil` to any of them raises `ConfigurationError`, so an unset environment variable fails at boot instead of being ignored.

## Guarantees and limits

Covered by `spec/security/encoder_spec.rb` on both engines: round trips, tampering at several positions, another key, another tag, a cursor used as an ID and the reverse, malformed and truncated input, encrypted pagination and a tampered cursor.

- **Changing the key invalidates every ID and cursor already handed out.** Key rotation without breaking clients comes with versioned encoders (in development).
- **Encryption hides the ID; it does not authorize.** Whoever obtained a valid ID can still send it. What they may read is decided by the authorization module.
- IDs are longer than base64 ones: 28 extra bytes (nonce and authentication tag) before encoding.
- graphql-ruby decodes an `after:` cursor once per selection that uses it, so a tampered cursor can produce the same error more than once.
- graphql-ruby's own `node(id:)` field does not rescue errors: a refused ID answers `Invalid ID or cursor` while a missing record answers `null`. Look IDs up through `loads:` (or rescue `InvalidError` in `object_from_id`) when that difference matters.
