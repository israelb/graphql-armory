# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/caching/walk"
require "graphql/armory/caching/controls/walk_schema"

# The rules of design 3.2, one spec each, on the query objects the selected engine builds (`query.types`).
RSpec.describe GraphQL::Armory::Caching::Walk do
  let(:caching) { GraphQL::Armory::Caching }
  let(:schema) { caching::Controls::WalkSchema.example(next_default: ArmoryEngine.next?) }

  # The query object the engine would build for this request (both engines go through `schema.query_class`).
  def query(document, context: {}, operation_name: nil, schema: self.schema)
    built = schema.query_class.new(schema, document, context: context, operation_name: operation_name)
    built.context[:__graphql_execute_next] = true if ArmoryEngine.next?
    built
  end

  def walk(document, **options)
    caching::Walk.(query(document, **options))
  end

  def type_tags(*names) = names.map { |name| caching::Tags.type(name) }
  def custom_tags(*names) = names.map { |name| caching::Tags.custom(name) }

  describe "a cacheable operation" do
    it "takes the smallest TTL, keeps :public when every field is, and tags custom and returned types" do
      policy = walk(%({ nodes { id ... on Product { name label } } }))

      expect(policy).to be_cacheable
      expect([policy.ttl, policy.scope]).to eq([10, :public])
      expect(policy.tags).to eq((custom_tags("catalog", "labels") + type_tags("Node", "Product", "Invoice", "Secret")).sort)
    end

    it "is :viewer as soon as one selected field is" do
      policy = walk(%({ nodes { id } invoices { number } }))

      expect([policy.ttl, policy.scope]).to eq([30, :viewer])
    end

    it "answers a useful policy from Walk.new, with no dependency to configure, and Walk.call is the same" do
      document = %({ invoices { number } })

      expect(caching::Walk.new.(query(document))).to eq(caching::Walk.call(query(document)))
      expect(caching::Walk.build.(query(document))).to be_cacheable
    end
  end

  describe "declarations" do
    it "refuses a selected field that neither it nor its declaring owner declares (:undeclared_field)" do
      expect(walk(%({ nodes { ... on Secret { code } } })).reason).to eq(:undeclared_field)
    end

    it "refuses a field declared cache: false (:forbidden_field)" do
      expect(walk(%({ node(id: "S1") { ... on Secret { summary } } })).reason).to eq(:forbidden_field)
    end

    it "judges an inherited field by its declaring owner, never by the subclass's wider default" do
      expect(walk(%({ child { secret } })).reason).to eq(:undeclared_field)
      expect(walk(%({ child { name } }))).to be_cacheable
    end

    it "lets a partial declaration with no owner default raise its ConfigurationError (a definition error)" do
      partial = caching::Controls::WalkSchema.example(next_default: ArmoryEngine.next?, partial: true)

      expect { walk(%({ partial { code } }), schema: partial) }.to raise_error(caching::ConfigurationError, /ttl/)
    end
  end

  describe "abstract positions" do
    it "judges an interface field against every implementation's own definition: the most restrictive wins" do
      policy = walk(%({ nodes { label } }))

      expect([policy.ttl, policy.scope]).to eq([10, :viewer])
      expect(policy.tags).to include(*custom_tags("labels"))
    end

    it "judges an interface field an implementation inherits by the interface's declaration, not the implementation's" do
      policy = walk(%({ nodes { ... on Invoice { id } } }))

      expect([policy.ttl, policy.scope]).to eq([300, :public])
    end

    it "refuses an interface field one implementation forbids, though the interface declares it" do
      expect(walk(%({ nodes { summary } })).reason).to eq(:forbidden_field)
    end

    it "tags a union and every possible type, and refuses a field selected on the union itself" do
      policy = walk(%({ search { __typename ... on Product { name } ... on Invoice { number } } }))

      expect([policy.ttl, policy.scope]).to eq([30, :viewer])
      expect(policy.tags).to include(*type_tags("SearchResult", "Product", "Invoice"))
      expect(walk(%({ search { name } })).reason).to eq(:unknown_field)
    end
  end

  describe "fragments" do
    it "switches the owner to an inline fragment's type condition" do
      expect(walk(%({ nodes { ... on Invoice { number } } })).scope).to eq(:viewer)
    end

    it "switches the owner to a spread fragment's type condition, through nested spreads and aliases" do
      document = <<~GRAPHQL
        query { a: nodes { ...OnNode } }
        fragment OnNode on Node { ...OnInvoice }
        fragment OnInvoice on Invoice { n: number }
      GRAPHQL

      expect([walk(document).ttl, walk(document).scope]).to eq([30, :viewer])
    end

    it "refuses a spread of an undefined fragment or a type condition query.types does not know (:invalid_document)" do
      expect(walk(%({ nodes { ...Missing } })).reason).to eq(:invalid_document)
      expect(walk(%({ nodes { ... on Missing { id } } })).reason).to eq(:invalid_document)
    end

    it "terminates on fragments that spread each other (graphql-ruby refuses them when it runs)" do
      document = <<~GRAPHQL
        { nodes { ...A } }
        fragment A on Node { id ...B }
        fragment B on Node { label ...A }
      GRAPHQL

      expect(walk(document)).to be_a(caching::Policy)
    end
  end

  describe "directives" do
    it "ignores @skip and @include: both branches count" do
      expect(walk(%({ nodes { id ... on Secret @skip(if: true) { code } } })).reason).to eq(:undeclared_field)
      expect(walk(%(query($x: Boolean!) { nodes { id } invoices @include(if: $x) { number } })).scope).to eq(:viewer)
    end

    {
      "the operation" => %(query Q @%s { nodes { id } }),
      "a field" => %({ nodes @%s { id } }),
      "a fragment definition" => %({ nodes { ...F } } fragment F on Node @%s { id }),
      "an inline fragment" => %({ nodes { ... on Product @%s { name } } }),
      "a fragment spread" => %({ nodes { ...F @%s } } fragment F on Node { id }),
      "a variable definition" => %(query($id: ID! @%s) { node(id: $id) { id } })
    }.each do |where, template|
      it "refuses a directive on #{where} unless its class declares cache_safe (:directive)" do
        expect(walk(format(template, "flagged")).reason).to eq(:directive)
        expect(walk(format(template, "hint"))).to be_cacheable
      end
    end

    it "refuses a directive the schema does not define, and one in an operation that is not selected" do
      expect(walk(%({ nodes @unknown { id } })).reason).to eq(:directive)
      expect(walk(%(query A { nodes { id } } query B { nodes @flagged { id } }), operation_name: "A").reason).to eq(:directive)
    end
  end

  describe "introspection" do
    it "allows __typename anywhere, without a declaration" do
      expect(walk(%({ nodes { __typename id } })).ttl).to eq(300)
    end

    it "refuses an operation that selects only __typename: nothing declares a TTL (:undeclared_field)" do
      expect(walk(%({ __typename })).reason).to eq(:undeclared_field)
    end

    it "refuses __schema and __type, also inside a fragment (:introspection)" do
      expect(walk(%({ __schema { queryType { name } } })).reason).to eq(:introspection)
      expect(walk(%({ __type(name: "Product") { name } })).reason).to eq(:introspection)
      expect(walk(%({ ...F } fragment F on Query { __type(name: "Product") { name } })).reason).to eq(:introspection)
    end
  end

  describe "Relay connections" do
    it "lets graphql-ruby's generated connection, edge and PageInfo fields take the declaration of the connection field" do
      policy = walk(<<~GRAPHQL)
        { products { edges { cursor node { name } } nodes { id } pageInfo { hasNextPage hasPreviousPage startCursor endCursor } } }
      GRAPHQL

      expect([policy.ttl, policy.scope]).to eq([300, :public])
      expect(policy.tags).to include(*type_tags("ProductConnection", "ProductEdge", "PageInfo", "Product"))
    end

    it "requires a declaration for a field the app adds to a connection" do
      expect(walk(%({ counted { totalCount } })).reason).to eq(:undeclared_field)
      expect(walk(%({ counted { edges { node { name } } } }))).to be_cacheable
    end

    it "requires a declaration for a connection field the app resolves itself" do
      expect(walk(%({ curated { nodes { name } } })).reason).to eq(:undeclared_field)
      expect(walk(%({ curated { edges { node { name } } } }))).to be_cacheable
    end

    it "still requires a declaration for the fields under a node" do
      expect(walk(%({ products { nodes { ... on Product { name } } edges { node { ... on Node { summary } } } } })).reason)
        .to eq(:forbidden_field)
    end

    it "describes a schema the selected engine runs" do
      result = execute_query(schema, %({ products { edges { cursor node { name } } pageInfo { hasNextPage } } }))

      expect(result["errors"]).to be_nil
      expect(result.dig("data", "products", "edges").map { |edge| edge.dig("node", "name") }).to eq(%w[Lamp Desk])
    end
  end

  describe "what query.types does not show" do
    it "refuses a field the document names but the schema does not have (:unknown_field)" do
      expect(walk(%({ nope })).reason).to eq(:unknown_field)
    end

    it "refuses a field hidden from this query's context, and allows it where it is visible" do
      expect(walk(%({ internalNote }), context: { hide_internal_note: true }).reason).to eq(:unknown_field)
      expect(walk(%({ internalNote }))).to be_cacheable
    end
  end

  describe "operations" do
    it "refuses a query with no selected operation (:no_operation)" do
      expect(walk("").reason).to eq(:no_operation)
      expect(walk("{ nodes { id ").reason).to eq(:no_operation)
      expect(walk(%(query A { nodes { id } }), operation_name: "B").reason).to eq(:no_operation)
      expect(walk(%(query A { nodes { id } } query B { nodes { id } })).reason).to eq(:no_operation)
    end

    it "refuses mutations and subscriptions" do
      expect(walk(%(mutation { touch })).reason).to eq(:mutation)
      expect(walk(%(subscription { ticked })).reason).to eq(:subscription)
    end
  end

  describe "memoization" do
    it "answers the same Policy for the same query object" do
      walker = caching::Walk.new
      built = query(%({ nodes { id } }))

      expect(walker.(built)).to equal(walker.(built))
    end

    it "walks every query object again: the same document can be judged differently per context" do
      walker = caching::Walk.new
      document = %({ internalNote })

      expect(walker.(query(document))).to be_cacheable
      expect(walker.(query(document, context: { hide_internal_note: true })).reason).to eq(:unknown_field)
    end
  end
end
