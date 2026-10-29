# Migrating from manual `authorized?`

The usual hand-written setup has three weak spots: every type needs its own `authorized?`, a forgotten type is open, and lookups by ID skip the check. This guide moves them to graphql-armory one step at a time. Each step leaves the app working.

## 1. Install the plugin and the bases

```ruby
class AppSchema < GraphQL::Schema
  use GraphQL::Armory::Authorization, adapter: :pundit
end
```

Make your base classes include `GraphQL::Armory::Authorization::Base` (see the README quick start). Types that inherit from them are now covered; run the audit to see the rest.

## 2. Replace `authorized?` with a rule

Before:

```ruby
class InvoiceType < BaseObject
  def self.authorized?(object, context)
    super && InvoicePolicy.new(context[:current_user], object).read?
  end
end
```

After: delete the method. `default_action :read` on the base (or `authorize :read` on the type) asks the same `InvoicePolicy#read?`.

## 3. Replace `scope_items` and list resolvers

Before:

```ruby
def self.scope_items(items, context)
  InvoicePolicy::Scope.new(context[:current_user], items).resolve
end
```

After: delete it. Lists of the type go through `InvoicePolicy::Scope` automatically, before pagination.

## 4. Replace lookups by ID

Before:

```ruby
field :invoice, InvoiceType do
  argument :id, ID
end
def invoice(id:) = Invoice.find(id)          # IDOR: any ID works
```

After:

```ruby
field :invoice, InvoiceType, authorize: :none, reason: "looked up through the scope", find_by: :id do
  argument :id, ID
end
```

For `loads:` arguments nothing changes in your code: they now resolve inside the scope. Another tenant's ID answers like a missing record.

## 5. Declare field-level rules

```ruby
field :internal_notes, String, authorize: :manage
```

A field with no rule on a bypassed type is denied until it declares one.

## 6. Make CI watch

```ruby
expect(AppSchema).to be_fully_authorized
```

## Check your migration

- The audit reports no problems, and every bypass has a reason you can defend.
- A test per sensitive type: user A asks for user B's record by root field, association and `loads:`; the answer matches a missing record.
- Policies return `true`/`false`/`nil` only.

## Known differences

- Arguments, mutations, interfaces and unions are not covered yet; keep your manual checks there.
- Policies without a `Scope` class are flagged by the audit for every type that uses them.
