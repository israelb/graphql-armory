# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/walk"
require "graphql/armory/caching/controls/walk_schema"

# Attack list item 2 (design section 9): make the walk miss a selected field. A miss would let an undeclared,
# forbidden or per-viewer field into a cacheable (or :public) policy. Every probe must be refused.
RSpec.describe "Response caching: the walk misses no selected field" do
  let(:caching) { GraphQL::Armory::Caching }
  let(:schema) { caching::Controls::WalkSchema.example(next_default: ArmoryEngine.next?) }

  def walk(document, schema: self.schema, **options)
    built = schema.query_class.new(schema, document, **options)
    built.context[:__graphql_execute_next] = true if ArmoryEngine.next?
    caching::Walk.(built)
  end

  it "a fragment on an interface reaches an implementation that forbids the field" do
    expect(walk(%({ nodes { ...F } } fragment F on Node { summary })).reason).to eq(:forbidden_field)
  end

  it "a fragment on an interface reaches an implementation that narrows the field: the narrower TTL wins" do
    expect(walk(%({ nodes { ...F } } fragment F on Node { label })).ttl).to eq(10)
  end

  it "nested fragment spreads behind aliases reach an undeclared field" do
    document = <<~GRAPHQL
      query { x: node(id: "S1") { ...A } }
      fragment A on Node { ...B }
      fragment B on Node { ... on Secret { y: code } }
    GRAPHQL

    expect(walk(document).reason).to eq(:undeclared_field)
  end

  it "the same fragment spread twice, once where it is harmless, is still judged" do
    document = <<~GRAPHQL
      { a: nodes { ...F } b: search { ... on Node { ...F } } }
      fragment F on Node { summary }
    GRAPHQL

    expect(walk(document).reason).to eq(:forbidden_field)
  end

  it "an interface fragment on a union reaches an implementation outside the union" do
    expect(walk(%({ search { ... on Node { summary } } })).reason).to eq(:forbidden_field)
  end

  it "an implementation that redefines an interface field as per-viewer makes the policy :viewer" do
    expect(walk(%({ nodes { ...F } } fragment F on Node { label })).scope).to eq(:viewer)
  end

  it "a connection whose nodes the app resolves itself is not a generated field" do
    expect(walk(%({ curated { nodes { name } } })).reason).to eq(:undeclared_field)
  end

  it "an app field on a connection is not a generated field" do
    expect(walk(%({ counted { totalCount } })).reason).to eq(:undeclared_field)
  end

  it "an inherited field under a subclass's wider cache_fields stays undeclared" do
    expect(walk(%({ child { name secret } })).reason).to eq(:undeclared_field)
  end

  it "a directive on a fragment definition or a variable definition refuses the operation" do
    expect(walk(%({ nodes { ...F } } fragment F on Node @flagged { id })).reason).to eq(:directive)
    expect(walk(%(query($id: ID! @flagged) { node(id: $id) { id } })).reason).to eq(:directive)
  end

  it "a directive inside a fragment no one spreads still refuses the operation" do
    expect(walk(%({ nodes { id } } fragment Unused on Node { id @flagged })).reason).to eq(:directive)
  end

  it "@skip does not hide a field from the walk, and an app class named skip is not ignored" do
    expect(walk(%({ nodes { id ... on Secret { code @skip(if: true) } } })).reason).to eq(:undeclared_field)

    replaced = caching::Controls::WalkSchema.example(next_default: ArmoryEngine.next?, replaced_skip: true)
    expect(walk(%({ nodes { id @skip(if: false) } }), schema: replaced).reason).to eq(:directive)
  end

  it "a field hidden from this context is refused, not judged by the schema's definition" do
    expect(walk(%({ internalNote }), context: { hide_internal_note: true }).reason).to eq(:unknown_field)
  end

  it "introspection behind a fragment and an alias is refused" do
    document = %({ ...F } fragment F on Query { s: __schema { types { name } } })

    expect(walk(document).reason).to eq(:introspection)
  end

  it "a type tag is emitted for every type an abstract position can return, so a type purge reaches it" do
    tags = walk(%({ nodes { id } })).tags

    expect(tags).to include(*%w[Node Product Invoice Secret].map { |name| caching::Tags.type(name) })
  end
end
