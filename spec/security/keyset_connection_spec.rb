# frozen_string_literal: true

require "base64"
require "json"

# A keyset connection pages by the values of its ordering columns, so rows that come and go between pages neither
# skip nor repeat items. Those values are in the cursor, which is why the default Base64 cursors are refused.
RSpec.describe GraphQL::Armory::Keyset do
  let(:controls) { GraphQL::Armory::Keyset::Controls }
  let(:encoder) { GraphQL::Armory::IDs::Controls::Encoder.example }
  let(:encrypted) { controls::Schema.example(base: base_schema, cursor_encoder: encoder) }
  let(:plain) { controls::Schema.example(base: base_schema) }

  let(:query) do
    <<~GRAPHQL
      query($first: Int, $after: String, $last: Int, $before: String) {
        items(first: $first, after: $after, last: $last, before: $before) {
          nodes { id }
          edges { cursor }
          pageInfo { hasNextPage hasPreviousPage startCursor endCursor }
        }
      }
    GRAPHQL
  end

  def page(connection, schema: encrypted, **variables)
    execute_query(schema, query, variables: variables.transform_keys(&:to_s), root_value: controls::Root.example(connection)).to_h
  end

  def ids(result)
    result.dig("data", "items", "nodes").map { |node| node["id"].to_i }
  end

  def info(result, name)
    result.dig("data", "items", "pageInfo", name)
  end

  def pages(result)
    [info(result, "hasNextPage"), info(result, "hasPreviousPage")]
  end

  def keyset(relation = KeysetItem.order(:id), **options)
    described_class.build(relation, **options)
  end

  def items(count)
    Array.new(count) { |index| KeysetItem.create!(rank: index).id }
  end

  describe "paging" do
    it "walks every row once, forward" do
      all = items(5)
      first = page(keyset, first: 2)
      second = page(keyset, first: 2, after: info(first, "endCursor"))
      third = page(keyset, first: 2, after: info(second, "endCursor"))

      expect(ids(first) + ids(second) + ids(third)).to eq(all)
      expect(pages(first)).to eq([true, false])
      expect(pages(second)).to eq([true, true])
      expect(pages(third)).to eq([false, true])
    end

    it "walks every row once, backward, in the same order" do
      all = items(5)
      last = page(keyset, last: 2)
      before = page(keyset, last: 2, before: info(last, "startCursor"))

      expect(ids(last)).to eq(all.last(2))
      expect(ids(before)).to eq(all[1, 2])
      expect(pages(last)).to eq([false, true])
      expect(pages(before)).to eq([true, true])
    end

    it "answers the rows between after and before" do
      all = items(5)
      cursors = page(keyset, first: 5).dig("data", "items", "edges").map { |edge| edge["cursor"] }
      between = page(keyset, first: 5, after: cursors[0], before: cursors[3])

      expect(ids(between)).to eq(all[1, 2])
      expect(pages(between)).to eq([true, true])
    end

    it "does not skip or repeat a row when rows are inserted before the cursor or the cursor's row is deleted" do
      all = items(4)
      first = page(keyset(KeysetItem.order(rank: :asc)), first: 2)
      KeysetItem.create!(rank: -1)
      KeysetItem.find(all[1]).destroy!
      second = page(keyset(KeysetItem.order(rank: :asc)), first: 2, after: info(first, "endCursor"))

      expect(ids(first)).to eq(all.first(2))
      expect(ids(second)).to eq(all.last(2))
    end

    it "breaks ties on the primary key, so rows with the same value are not lost" do
      all = Array.new(5) { KeysetItem.create!(rank: 7).id }
      relation = KeysetItem.order(:rank)
      first = page(keyset(relation), first: 2)
      second = page(keyset(relation), first: 3, after: info(first, "endCursor"))

      expect(ids(first) + ids(second)).to eq(all)
    end

    it "pages columns in mixed directions" do
      a = KeysetItem.create!(rank: 1, name: "b").id
      b = KeysetItem.create!(rank: 1, name: "a").id
      c = KeysetItem.create!(rank: 2, name: "c").id
      relation = KeysetItem.order(rank: :desc, name: :asc)
      first = page(keyset(relation), first: 2)
      second = page(keyset(relation), first: 2, after: info(first, "endCursor"))

      expect(ids(first)).to eq([c, b])
      expect(ids(second)).to eq([a])
    end

    it "keeps microseconds in the cursor" do
      base = Time.utc(2026, 1, 1, 0, 0, 0)
      all = [1, 2, 3].map { |micro| KeysetItem.create!(happened_at: base + Rational(micro, 1_000_000)).id }
      relation = KeysetItem.order(:happened_at)
      first = page(keyset(relation), first: 1)
      second = page(keyset(relation), first: 2, after: info(first, "endCursor"))

      expect(ids(first) + ids(second)).to eq(all)
    end

    it "pages decimals" do
      all = %w[1.10 1.20 1.30].map { |amount| KeysetItem.create!(amount: amount).id }
      relation = KeysetItem.order(:amount)
      first = page(keyset(relation), first: 1)

      expect(ids(page(keyset(relation), first: 2, after: info(first, "endCursor")))).to eq(all.last(2))
    end

    it "honours first: 0 and the schema's max page size" do
      items(3)
      capped = controls::Schema.example(base: base_schema, cursor_encoder: encoder, max_page_size: 2)

      expect(ids(page(keyset, first: 0))).to eq([])
      expect(ids(page(keyset, schema: capped, first: 3)).size).to eq(2)
    end

    it "refuses first and last together instead of ignoring one" do
      items(3)
      result = page(keyset, first: 1, last: 1)

      expect(result.dig("errors", 0, "message")).to match(/first.*last/i)
      expect(result.dig("data", "items", "nodes")).to be_nil
    end
  end

  describe "cursors" do
    let(:base64) { GraphQL::Schema::Base64Encoder }

    def forge(key, order: "keyset_items.id:asc", version: 1)
      base64.encode({ v: version, o: order, k: key }.to_json, nonce: true)
    end

    it "refuses the default Base64 encoder unless plain_cursors: true" do
      items(1)

      expect { page(keyset, schema: plain, first: 1) }.to raise_error(described_class::ConfigurationError, /plain_cursors/)
      expect(ids(page(keyset(plain_cursors: true), schema: plain, first: 1)).size).to eq(1)
    end

    it "refuses a plain_cursors: that is not a boolean" do
      expect { keyset(plain_cursors: "yes") }.to raise_error(described_class::ConfigurationError, /plain_cursors/)
    end

    it "does not show the ordering values in an encrypted cursor" do
      KeysetItem.create!(rank: 987_654)
      cursor = info(page(keyset(KeysetItem.order(:rank)), first: 1), "endCursor")

      expect(Base64.urlsafe_decode64(cursor)).not_to include("987654")
    end

    it "refuses a tampered cursor like any other invalid one" do
      items(2)
      cursor = info(page(keyset, first: 1), "endCursor")
      tampered = cursor.sub(/.\z/) { |last| last == "A" ? "B" : "A" }
      result = page(keyset, first: 1, after: tampered)

      expect(result.dig("errors", 0, "message")).to eq("Invalid ID or cursor")
      expect(result.dig("data", "items", "nodes")).to be_nil
    end

    it "refuses a cursor made for another ordering" do
      items(2)
      cursor = info(page(keyset(KeysetItem.order(:rank)), first: 1), "endCursor")
      result = page(keyset(KeysetItem.order(:id)), first: 1, after: cursor)

      expect(result.dig("errors", 0, "message")).to eq("Invalid ID or cursor")
    end

    it "refuses forged plain cursors with the same message" do
      items(2)
      forged = [
        "not base64 !!",
        base64.encode("not json", nonce: true),
        base64.encode("[1]", nonce: true),
        base64.encode("\xFF\xFE".b, nonce: true),
        forge([1], version: 2),
        forge([]),
        forge([1, 2]),
        forge([{ a: 1 }]),
        forge([[1]]),
        forge([nil]),
        forge([10**40]),
        forge("1")
      ]

      forged.each do |cursor|
        result = page(keyset(plain_cursors: true), schema: plain, first: 1, after: cursor)
        expect(result.dig("errors", 0, "message")).to eq("Invalid ID or cursor"), "cursor #{cursor.inspect}: #{result}"
      end
    end

    it "refuses a forged date that does not parse" do
      KeysetItem.create!
      cursor = forge(["nope", 1], order: "keyset_items.happened_at:asc,keyset_items.id:asc")
      result = page(keyset(KeysetItem.order(:happened_at), plain_cursors: true), schema: plain, first: 1, after: cursor)

      expect(result.dig("errors", 0, "message")).to eq("Invalid ID or cursor")
    end

    it "binds cursor values, so SQL in a cursor is only a value" do
      KeysetItem.create!(name: "a")
      KeysetItem.create!(name: "b")
      cursor = forge(["z' OR 1=1 --", 0], order: "keyset_items.name:asc,keyset_items.id:asc")
      result = page(keyset(KeysetItem.order(:name), plain_cursors: true), schema: plain, first: 5, after: cursor)

      expect(ids(result)).to eq([])
    end
  end

  describe "orderings it cannot page" do
    {
      "a raw SQL order" => -> { KeysetItem.order(Arel.sql("rank + 1")) },
      "a string order" => -> { KeysetItem.order("rank ASC") },
      "a nullable column" => -> { KeysetItem.order(:note) },
      "a float column" => -> { KeysetItem.order(:score) },
      "nulls first" => -> { KeysetItem.order(KeysetItem.arel_table[:rank].asc.nulls_first) },
      "a column of another table" => -> { KeysetItem.order(Invoice.arel_table[:id].asc) },
      "a limit" => -> { KeysetItem.order(:id).limit(2) },
      "an offset" => -> { KeysetItem.order(:id).offset(2) },
      "a group" => -> { KeysetItem.group(:rank).order(:rank) },
      "a select" => -> { KeysetItem.select(:name).order(:id) }
    }.each do |name, relation|
      it "refuses #{name}" do
        expect { described_class.build(relation.call) }.to raise_error(described_class::ConfigurationError)
      end
    end

    it "refuses what is not a relation" do
      expect { described_class.build([1, 2]) }.to raise_error(described_class::ConfigurationError, /relation/)
    end
  end

  describe ".new" do
    it "is inert: no relation, no rows, no pages, no cursor" do
      connection = described_class.new

      expect(connection.nodes).to eq([])
      expect(connection.has_next_page).to be(false)
      expect(connection.has_previous_page).to be(false)
      expect(connection.cursor_for(Object.new)).to be_nil
    end
  end

  describe "with authorization" do
    let(:world) { Dummy::World.build }

    def scoped_schema(adapter: :pundit, **rule_options)
      armory = GraphQL::Armory
      cursors = encoder
      base_field = Class.new(GraphQL::Schema::Field) { include armory::Authorization::Base }
      base_object = Class.new(GraphQL::Schema::Object) do
        include armory::Authorization::Base
        field_class base_field
      end
      invoice = Class.new(base_object) do
        graphql_name "Invoice"
        authorize :read, model: ::Invoice, **rule_options
        field :id, String, null: false, authorize: :none, reason: "ids are public"
      end
      root = Class.new(base_object) do
        graphql_name "Query"
        authorize :none, reason: "the root holds nothing"
        field :items, invoice.connection_type, null: false, authorize: :none, reason: "scoped by the node type"
      end
      Class.new(base_schema) do
        use armory::Authorization, adapter: adapter
        cursor_encoder cursors
        query(root)
      end
    end

    def scoped_page(schema, user, **variables)
      execute_query(schema, query, variables: variables.transform_keys(&:to_s), context: { current_user: user },
                                   root_value: controls::Root.example(keyset(Invoice.order(:id)))).to_h
    end

    it "pages inside the user's scope" do
      expect(ids(scoped_page(scoped_schema, world.alice, first: 5))).to eq([world.a1.id, world.a2.id])
      expect(ids(scoped_page(scoped_schema, world.bob, first: 5))).to eq([world.b1.id])
    end

    it "keeps another user's cursor inside the scope of whoever uses it" do
      schema = scoped_schema
      world
      cursor = info(scoped_page(schema, world.bob, first: 1), "startCursor")

      expect(ids(scoped_page(schema, world.alice, first: 5, before: cursor))).to eq([world.a1.id, world.a2.id])
    end

    it "does not count rows outside the scope in hasPreviousPage or hasNextPage" do
      schema = scoped_schema
      world
      first = scoped_page(schema, world.alice, first: 2)
      cursor = info(first, "endCursor")
      after = scoped_page(schema, world.alice, first: 2, after: cursor)

      expect(pages(first)).to eq([false, false])
      expect(ids(after)).to eq([])
      expect(info(after, "hasNextPage")).to be(false)
    end

    it "refuses an in-memory scope, which yields no relation to page" do
      adapter = GraphQL::Armory::Authorization::Adapters::CanCan.new(ability_class: BlockAbility)

      expect { scoped_page(scoped_schema(adapter: adapter, scope: :in_memory), world.alice, first: 1) }
        .to raise_error(described_class::ConfigurationError, /relation/)
    end

    it "pages inside a CanCanCan ability" do
      expect(ids(scoped_page(scoped_schema(adapter: :cancan), world.bob, first: 5))).to eq([world.b1.id])
    end
  end
end
