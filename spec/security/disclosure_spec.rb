# frozen_string_literal: true

# What the client can learn without reading data: that something exists, how it is named, who denied it.
RSpec.describe "Disclosure" do
  let(:authorization) { GraphQL::Armory::Authorization }

  describe "errors" do
    let(:denied_in_every_path) do
      [
        as(world.alice, "{ myInvoice { number } }", mode: :error, my_invoice: world.b1),
        as(world.alice, "{ myAccount { name } }", mode: :error, my_account: world.account_b),
        load_by(world.alice, world.b1.id, mode: :error)
      ]
    end

    it "are the same generic answer on every path" do
      errors = denied_in_every_path.flat_map { |result| result["errors"].map { |e| e.slice("message", "extensions") } }

      expect(errors.uniq).to eq([{ "message" => "Not found", "extensions" => { "code" => "NOT_FOUND" } }])
    end

    it "name no type, policy, record or id" do
      text = denied_in_every_path.flat_map { |result| result["errors"].map { |e| e.slice("message", "extensions") } }.to_s

      expect(text).not_to match(/Invoice|Account|Policy|authoriz|B-1|#{world.b1.id}/)
    end
  end

  describe "telemetry" do
    it "records types, actions and reasons, never record attributes" do
      as(world.carol, "{ myInvoice { id number internalNotes account { name } } }", my_invoice: world.a1)
      as(world.alice, "{ myInvoice { number } }", my_invoice: world.b1)

      expect(telemetry.map(&:first).uniq).to include(:allowed, :denied, :bypassed)
      expect(telemetry.flat_map { |_signal, data| data.keys }.uniq).to all(be_in(%i[type action reason]))
      expect(telemetry.to_s).not_to match(/secret|A-1|B-1/)
    end
  end

  # graphql-ruby, not this gem, hides a member that `visible?` rejects. The gem relies on it for
  # the guarantee below, so it is pinned here on both engines; armory's own visibility rules come later.
  describe "a field hidden with visible?" do
    Staff = Struct.new(:my_invoice)

    def staff_schema
      armory = GraphQL::Armory::Authorization
      field_class = Class.new(GraphQL::Schema::Field) do
        include armory::Base

        def initialize(*args, staff_only: false, **kwargs, &block)
          @staff_only = staff_only
          super(*args, **kwargs, &block)
        end

        def visible?(context)
          super && (!@staff_only || context[:staff] == true)
        end
      end
      object = Class.new(GraphQL::Schema::Object) do
        include armory::Base
        field_class field_class
      end
      invoice = Class.new(object) do
        graphql_name "Invoice"
        authorize :none, reason: "this spec is about visibility"
        field :number, String, null: false, authorize: :none, reason: "public"
        field :internal_notes, String, staff_only: true, authorize: :none, reason: "hidden from non-staff"
      end
      query = Class.new(object) do
        graphql_name "Query"
        authorize :none, reason: "root"
        field :my_invoice, invoice, authorize: :none, reason: "root"
      end

      Class.new(ArmoryEngine.base_schema) do
        query query
        use armory, adapter: :pundit
      end
    end

    def run_as(staff, query)
      execute_query(staff_schema, query, context: { current_user: world.alice, staff: staff },
                                         root_value: Staff.new(world.a1))
    end

    it "is absent from introspection for those who cannot see it" do
      query = '{ __type(name: "Invoice") { fields { name } } }'

      names = ->(staff) { run_as(staff, query).dig("data", "__type", "fields").map { |f| f["name"] }.sort }

      expect([names.(false), names.(true)]).to eq([%w[number], %w[internalNotes number]])
    end

    it "is absent from error suggestions for those who cannot see it" do
      typo = "{ myInvoice { internalNote } }"

      hidden = run_as(false, typo)["errors"].to_s
      shown = run_as(true, typo)["errors"].to_s

      expect(shown).to include("internalNotes")
      expect(hidden).not_to include("internalNotes")
    end

    it "answers a query for it exactly like a field that never existed" do
      hidden = run_as(false, "{ myInvoice { internalNotes } }")["errors"]
      never = run_as(false, "{ myInvoice { neverExisted } }")["errors"]

      expect(hidden.map { |e| e["message"].sub("internalNotes", "X") }).to eq(never.map { |e| e["message"].sub("neverExisted", "X") })
    end
  end
end
