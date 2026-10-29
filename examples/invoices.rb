# frozen_string_literal: true

# A complete, runnable setup: plain Pundit policies, a schema that cannot forget to authorize, and the audit.
#
#   docker compose run --rm test bundle exec ruby examples/invoices.rb
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "graphql/armory"
require "pundit"

module InvoicesExample
  User = Struct.new(:id, :account_id, :admin, keyword_init: true) do
    alias_method :admin?, :admin
  end
  Invoice = Struct.new(:number, :account_id, :internal_notes, keyword_init: true)

  # Plain Pundit: nothing here knows about GraphQL or graphql-armory.
  class InvoicePolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    def read?
      record.account_id == user.account_id
    end

    def manage?
      user.admin?
    end

    class Scope
      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        @scope.select { |invoice| invoice.account_id == @user.account_id }
      end
    end
  end

  # Every type and field of the app inherits from these two bases; that is where coverage comes from.
  class BaseField < GraphQL::Schema::Field
    include GraphQL::Armory::Authorization::Base
  end

  class BaseObject < GraphQL::Schema::Object
    include GraphQL::Armory::Authorization::Base
    field_class BaseField
    default_action :read
  end

  class InvoiceType < BaseObject
    graphql_name "Invoice"
    authorize :read, model: Invoice

    field :number, String, null: false
    field :internal_notes, String, authorize: :manage
  end

  class QueryType < BaseObject
    graphql_name "Query"
    authorize :none, reason: "root type; each field declares its own rule"

    field :invoices, [InvoiceType], null: false, authorize: :none, reason: "narrowed by InvoicePolicy::Scope"
  end

  class Schema < GraphQL::Schema
    query QueryType
    use GraphQL::Armory::Authorization, adapter: :pundit
  end

  Root = Struct.new(:invoices)

  INVOICES = [
    Invoice.new(number: "A-1", account_id: 1, internal_notes: "pays late"),
    Invoice.new(number: "A-2", account_id: 1, internal_notes: "vip"),
    Invoice.new(number: "B-1", account_id: 2, internal_notes: "other tenant")
  ].freeze

  def self.run(user, query = "{ invoices { number internalNotes } }")
    Schema.execute(query, context: { current_user: user }, root_value: Root.new(INVOICES))
  end

  def self.audit
    GraphQL::Armory::Authorization::Audit.(Schema)
  end
end

if $PROGRAM_NAME == __FILE__
  alice = InvoicesExample::User.new(id: 1, account_id: 1, admin: false)
  carol = InvoicesExample::User.new(id: 3, account_id: 1, admin: true)

  puts "alice (member of account 1):"
  p InvoicesExample.run(alice).to_h
  puts "carol (admin of account 1):"
  p InvoicesExample.run(carol).to_h
  puts "audit:"
  puts InvoicesExample.audit
end
