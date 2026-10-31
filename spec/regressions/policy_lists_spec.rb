# frozen_string_literal: true

require "delegate"

# Recheck of item 2: a list that is not a real relation fails closed without model:, and works with it.
ActiveRecord::Base.connection.create_table(:rk_notes, force: true) { |t| t.string :secret }

class RkNote < ActiveRecord::Base; end

class RkNotePolicy
  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      return @scope if @user == :admin

      @scope.respond_to?(:none) ? @scope.none : []
    end
  end

  def initialize(user, _record) = @user = user
  def read? = @user == :admin
end

# Stand-in for a Mongoid criteria: a list with a klass, not an ActiveRecord relation.
class RkCriteria
  include Enumerable
  def initialize(rows) = @rows = rows
  def klass = RkNote
  def each(&block) = @rows.each(&block)
  def none = self.class.new([])
end

RSpec.describe "RECHECK: lists that are not relations" do
  let(:armory) { GraphQL::Armory::Authorization }
  let(:adapter) { armory::Adapters::Pundit.new }
  let(:read) { armory::Rule.new(:read) }
  let(:read_note) { armory::Rule.new(:read, model: RkNote) }

  before do
    RkNote.delete_all
    RkNote.create!(secret: "SECRET")
  end

  def list_schema(**rule)
    plugin = armory
    argument = Class.new(GraphQL::Schema::Argument) { include plugin::Base }
    base_field = Class.new(GraphQL::Schema::Field) do
      include plugin::Base
      argument_class argument
    end
    object = Class.new(GraphQL::Schema::Object) do
      include plugin::Base
      field_class base_field
    end
    note = Class.new(object) do
      graphql_name "Note"
      authorize :read, **rule
      field :secret, String, null: true
    end
    query_class = Class.new(object) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :notes, [note], null: true, authorize: :none, reason: "x"
    end
    Class.new(base_schema) do
      use plugin, adapter: :pundit
      query query_class
    end
  end

  def run_list(list, user:, **rule)
    result = execute_query(list_schema(**rule), "{ notes { secret } }", root_value: Struct.new(:notes).new(list), context: { current_user: user }).to_h
    puts "OUT #{RSpec.current_example.description[0, 4]} #{user} => #{result.inspect}"
    result
  rescue StandardError => error
    puts "OUT #{RSpec.current_example.description[0, 4]} #{user} RAISED #{error.class}: #{error.message}"
    error
  end

  it "R01 security delegator around a relation, adapter scope, no model: raises NotDefinedError" do
    expect { adapter.scope(:admin, SimpleDelegator.new(RkNote.all), read) }.to raise_error(Pundit::NotDefinedError, /SimpleDelegator/)
  end

  it "R02 security delegator around a relation, end to end, no model: serves nothing to anybody" do
    # A class-derived type name would resolve nothing either: the type is anonymous to Pundit.
    [:someone, :admin].each do |user|
      expect(run_list(SimpleDelegator.new(RkNote.all), user: user, model: nil)).to be_a(Pundit::NotDefinedError)
    end
  end

  it "R03 preservation delegator around a relation, adapter scope, model: on the rule" do
    refused = adapter.scope(:someone, SimpleDelegator.new(RkNote.all), read_note)
    allowed = adapter.scope(:admin, SimpleDelegator.new(RkNote.all), read_note)
    expect(refused.to_a).to eq([])
    expect(allowed.map(&:secret)).to eq(["SECRET"])
  end

  it "R04 preservation delegator around a relation, end to end, model: on the type" do
    refused = run_list(SimpleDelegator.new(RkNote.all), user: :someone, model: RkNote)
    allowed = run_list(SimpleDelegator.new(RkNote.all), user: :admin, model: RkNote)
    expect(refused.to_s).not_to include("SECRET")
    expect(allowed.dig("data", "notes")).to eq([{ "secret" => "SECRET" }])
  end

  it "R05 security Mongoid-like criteria with klass, adapter scope, no model: raises, klass not read" do
    expect { adapter.scope(:admin, RkCriteria.new(RkNote.all.to_a), read) }.to raise_error(Pundit::NotDefinedError, /RkCriteria/)
  end

  it "R06 preservation Mongoid-like criteria, end to end, model: on the type" do
    refused = run_list(RkCriteria.new(RkNote.all.to_a), user: :someone, model: RkNote)
    allowed = run_list(RkCriteria.new(RkNote.all.to_a), user: :admin, model: RkNote)
    expect(refused.to_s).not_to include("SECRET")
    expect(allowed.dig("data", "notes")).to eq([{ "secret" => "SECRET" }])
  end

  it "R07 preservation an Array filters per item, with no model: and no ArrayPolicy" do
    rows = RkNote.all.to_a
    expect(adapter.scope(:someone, rows, read)).to eq([])
    expect(adapter.scope(:admin, rows, read)).to eq(rows)
  end
end
