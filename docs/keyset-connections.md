# Keyset connections

Pagination that stays correct while rows come and go.

## The problem

graphql-ruby's connection for ActiveRecord pages with `OFFSET`. If a row is inserted or deleted between two pages, every later row moves by one: the client sees a row twice, or never sees it. `OFFSET` also gets slower the deeper the page, because the database still walks the rows it skips.

## The solution

`GraphQL::Armory::Keyset` pages by the **values of the ordering columns**. The cursor says "after the row with these values", and the next page is a `WHERE` on them. A row inserted earlier in the list, or the deletion of the cursor's own row, changes nothing.

Those values are in the cursor, which creates a risk `OFFSET` cursors do not have. With graphql-ruby's default Base64 cursors, a client could read the value of a column you order by, even one that is not in your schema, and could forge a cursor to search it (`salary > X`, again and again, watching which rows appear). So the default encoder is refused unless you say otherwise.

## How to use it

Encrypt your cursors, and return a keyset connection from the resolver of a connection field:

```ruby
class AppSchema < GraphQL::Schema
  cursor_encoder AppEncoder # a GraphQL::Armory::Encoder subclass
end

class Types::Query < Types::BaseObject
  field :invoices, Types::Invoice.connection_type, null: false

  def invoices
    GraphQL::Armory::Keyset.build(Invoice.order(created_at: :desc))
  end
end
```

graphql-ruby fills in `first`, `after`, `last`, `before` and the page sizes, as for any connection. The rest of your connections keep their `OFFSET`: this is chosen per resolver, and not registered for every relation.

If the ordering values are not secret (a public list ordered by id), you can keep readable cursors:

```ruby
GraphQL::Armory::Keyset.build(Article.order(:id), plain_cursors: true)
```

### Checking the encoder when the app loads

Without more, a schema that cannot keep cursors private is refused on the first keyset page, in a request. `use` moves that to when the schema class loads, and looks further than the default encoder:

```ruby
class AppSchema < GraphQL::Schema
  cursor_encoder AppEncoder
  use GraphQL::Armory::Keyset # below cursor_encoder
end
```

It probes the encoder, and refuses one that does not give back what it encoded, leaves the text readable (plain, Base64 or hex, also behind a prefix, ROT13, reversed), changes only part of its output when the input changes (a fixed key, or a real cipher with a fixed nonce), or decodes forged text. Any encoder set later on that schema or on a subclass goes through the same check.

`use GraphQL::Armory::Keyset, plain_cursors: true` turns the check off and makes readable cursors the schema's default. Then `Keyset.build(relation)` needs no option of its own, and an explicit `plain_cursors:` on `build` still wins.

### What it can order by

The relation must be ordered by plain, non-null columns of its own table. The primary key is added as the last column, to break ties, so a relation with no order pages by primary key. `build` raises `Keyset::ConfigurationError` for:

- a raw SQL or string order (`order("rank ASC")`, `Arel.sql`), an expression, or `nulls_first`;
- a column of another table;
- a nullable column: SQL comparisons skip `NULL`, so those rows would be lost;
- a `float` column: equality on floats is not reliable. Allowed types are integer, string, text, decimal, datetime, date, boolean and uuid;
- a serialized or encrypted column: the database does not order those by the value a cursor would hold;
- a relation with `limit`, `offset`, `group` or `select`;
- a `joins` or `left_joins` without `distinct`, because a join can repeat a row. Add `.distinct`, or filter with a subquery.

Add an index on the ordering columns, in that order, ending with the primary key. Without one the database still has to sort.

### With authorization

A type that includes `GraphQL::Armory::Authorization::Base` scopes the relation inside the connection, as it does for a plain relation, so the page, `hasNextPage` and `hasPreviousPage` only see rows the user may see. A cursor adds a condition to that scope, so someone else's cursor cannot reach outside it. A scope that answers an Array (CanCanCan's `scope: :in_memory`) has nothing to page and raises `ConfigurationError`.

If your own type defines `scope_items`, it receives the `Keyset` object and not a relation. Call `items.rescoped { |relation| ... }` there.

### Testing

`Keyset::Controls::Schema.example(base:, cursor_encoder:, max_page_size:)` is a schema with one connection field, `items`, and `Keyset::Controls::Root.example(connection)` is its root value. `IDs::Controls::Encoder.example` is an encoder with a fixed test key. `Keyset.new`, with nothing wired, has no rows, no pages and no cursors.

## Reference

`use GraphQL::Armory::Keyset, plain_cursors: false`, optional, on a schema.

- `plain_cursors:` is `true` or `false`. `true` skips the check and is what `build` follows when it is given none. A subclass inherits it, and its own `use` replaces it.

`GraphQL::Armory::Keyset.build(relation, plain_cursors: nil)`

- `relation`: an ActiveRecord relation, checked as above.
- `plain_cursors:` is `true`, `false` or `nil`. `true` allows the schema's default Base64 encoder. `nil` follows the schema's `use`, or `false` with no `use`.

Errors:

| When | What |
|---|---|
| Boot or resolver, a relation it cannot page | `Keyset::ConfigurationError` |
| First page, the schema has the default encoder and no `plain_cursors: true` | `Keyset::ConfigurationError` |
| `use` or a later `cursor_encoder`, an encoder that fails the check | `Keyset::ConfigurationError`, naming an error's class and never its message |
| A cursor that is tampered, malformed, or made for another ordering | `Invalid ID or cursor`, the same for all |
| `first` and `last` together | `first and last cannot be used together` |

## Guarantees and limits

- Every row present for the whole walk is seen exactly once, whatever is inserted or deleted meanwhile.
- A row whose ordering value **changes** between pages can be skipped or seen twice: it really moved. Order by columns that do not change (a creation time, an id) when this matters.
- A row inserted behind the cursor is not seen on the way forward, as in any pagination.
- With no `use`, the encoder check runs on the first page and only knows the default Base64 encoder: a custom encoder that does not encrypt passes unnoticed.
- With `use`, the check runs when the schema class loads, which is not boot if your app autoloads it lazily, and it cannot prove encryption: a keyed cipher that fails none of the probes passes, sound or not. A keyset cursor is only as private as your `cursor_encoder`.
- The check calls your encoder when the schema loads, so an encoder whose key is not there yet (during `assets:precompile`, or set in a later initializer) is refused. Fix the load order, or leave out `use` for that step: the check on the first page stays.
- `Encoder.versioned(New, Encoder::Legacy)` is refused, because `Legacy` decodes forged Base64. During such a migration a client can make its own cursors, so state it with `plain_cursors: true`.
- A `Keyset` subclass that overrides `encode` or `decode` is not checked. Setting the encoder through `instance_variable_set` is not checked.
- With `plain_cursors: true` a client can read the ordering values and forge a cursor. It stays inside the scope and its values are bound, never interpolated, but it can probe those columns.
- A forged value on a plain cursor must have the form the column's own cursors have (an Integer, a plain decimal, an ISO 8601 date or time) or it is an invalid cursor. A forged value of the right form is honoured: it pages from there.
- Encryption keeps length, so the length of an encrypted cursor reveals roughly the length of a string ordering value.
- A value JSON cannot hold, such as Postgres `infinity` in an ordering column, raises when the cursor is built. Avoid it in columns you order by.
- A decimal of more than 65 digits on either side of the point, possible only on an unconstrained Postgres `numeric`, gets `Invalid ID or cursor` even on its own cursor. Give the column a precision.
- On `Execution::Next`, a node type with `reauthorize_scoped_objects(false)` skips `authorized?` even when its scope did not narrow the list. A plain relation does the same: it comes from graphql-ruby. Do not combine that setting with a scope that does not filter.
- There is no total count. `hasNextPage` costs no extra query going forward without `before`, nor does `hasPreviousPage` going backward without `after`; in the other cases each costs one query, only when the client asks for it.
- ActiveRecord only. The attributes of the ordering columns must be readable on each row, which is why `select` is refused.
