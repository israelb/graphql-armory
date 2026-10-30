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

    # Verifier probes: a short decimal like 1e99999999999 exhausted memory, and Postgres raised on a number as a date.
    it "refuses a forged value that is not the form the column's own cursors have" do
      KeysetItem.create!
      {
        "keyset_items.amount:asc" => ["1e5", 5, "1" * 200],
        "keyset_items.happened_at:asc" => [5, true, "tomorrow", "99999-01-01T00:00:00Z"],
        "keyset_items.rank:asc" => ["abc", "1", true]
      }.each do |column, values|
        name = column[/\.(\w+):/, 1]
        values.each do |value|
          cursor = forge([value, 1], order: "#{column},keyset_items.id:asc")
          result = page(keyset(KeysetItem.order(name.to_sym), plain_cursors: true), schema: plain, first: 1, after: cursor)
          expect(result.dig("errors", 0, "message")).to eq("Invalid ID or cursor"), "#{name} #{value.inspect}: #{result}"
        end
      end
    end

    it "answers the same error when a custom encoder raises or answers nil" do
      KeysetItem.create!
      [->(*) { raise OpenSSL::Cipher::CipherError }, ->(*) {}].each do |decoding|
        custom = Module.new do
          define_singleton_method(:encode) { |text, nonce: false| text }
          define_singleton_method(:decode) { |text, nonce: false| decoding.call(text) }
        end
        schema = controls::Schema.example(base: base_schema, cursor_encoder: custom)

        expect(page(keyset, schema: schema, first: 1, after: "x").dig("errors", 0, "message")).to eq("Invalid ID or cursor")
      end
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

    # Verifier probes: a join repeats rows, and these columns' values do not survive a trip through a cursor.
    it "refuses joins unless the relation is distinct" do
      expect { described_class.build(Account.joins(:users).order(:id)) }.to raise_error(described_class::ConfigurationError, /distinct/)
      expect { described_class.build(Account.left_joins(:users).order(:id)) }.to raise_error(described_class::ConfigurationError, /distinct/)

      account = Account.create!(name: "A")
      2.times { |index| User.create!(account: account, name: "u#{index}") }
      connection = described_class.build(Account.joins(:users).distinct.order(:id))

      expect(ids(page(connection, first: 5))).to eq([account.id])
    end

    def model_with(&body)
      Class.new(ActiveRecord::Base) do
        self.table_name = "keyset_items"
        define_singleton_method(:name) { "KeysetItemVariant" }
        class_eval(&body)
      end
    end

    it "refuses a serialized column" do
      model = model_with { serialize :name, coder: JSON }

      expect { described_class.build(model.order(:name)) }.to raise_error(described_class::ConfigurationError, /name/)
    end

    it "refuses an encrypted column" do
      model = model_with { encrypts :name }

      expect { described_class.build(model.order(:name)) }.to raise_error(described_class::ConfigurationError, /name/)
    end

    # Verifier recheck: `normalizes` declared last wraps the type and hid these from the check.
    it "refuses a serialized or encrypted column behind a later normalizes" do
      encrypted_model = model_with do
        encrypts :name
        normalizes :name, with: ->(value) { value.strip }
      end
      serialized_model = model_with do
        serialize :name, coder: JSON
        normalizes :name, with: ->(value) { value }
      end

      expect { described_class.build(encrypted_model.order(:name)) }.to raise_error(described_class::ConfigurationError, /name/)
      expect { described_class.build(serialized_model.order(:name)) }.to raise_error(described_class::ConfigurationError, /name/)
    end

    it "still pages a column that is only normalized" do
      model = model_with { normalizes :name, with: ->(value) { value.strip } }
      all = %w[a b c].map { |name| model.create!(name: name).id }
      relation = model.order(:name)
      first = page(described_class.build(relation), first: 1)

      expect(ids(page(described_class.build(relation), first: 2, after: info(first, "endCursor")))).to eq(all.last(2))
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

    it "stays inert when given a relation without going through build" do
      KeysetItem.create!

      expect(described_class.new(KeysetItem.all).nodes).to eq([])
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

    # Verifier probe: a new object on every scope told graphql-ruby the list was narrowed, so `authorized?` was skipped.
    it "keeps per-object checks when the scope did not narrow the list" do
      skip "Execution::Next skips them for a plain relation too" if ArmoryEngine.next?

      schema = scoped_schema
      type = schema.get_type("Invoice")
      type.authorize :none, reason: "checked per object"
      type.define_singleton_method(:authorized?) { |object, context| object.account_id == context[:current_user].account_id }
      type.reauthorize_scoped_objects(false)
      world
      nodes = scoped_page(schema, world.alice, first: 5).dig("data", "items", "nodes")

      expect(nodes.map { |node| node && node["id"].to_i }).to eq([world.a1.id, world.a2.id, nil])
    end

    # Verifier probe: `rescoped` built a new connection and lost what the resolver had set on it.
    it "keeps what the resolver set on the connection" do
      schema = scoped_schema
      world
      connection = keyset(Invoice.order(:id)).tap { |built| built.max_page_size = 1 }
      result = execute_query(schema, query, variables: { "first" => 5 }, context: { current_user: world.alice },
                                            root_value: controls::Root.example(connection)).to_h

      expect(ids(result)).to eq([world.a1.id])
      expect(info(result, "hasNextPage")).to be(true)
    end

    it "pages inside a CanCanCan ability" do
      expect(ids(scoped_page(scoped_schema(adapter: :cancan), world.bob, first: 5))).to eq([world.b1.id])
    end
  end
end
