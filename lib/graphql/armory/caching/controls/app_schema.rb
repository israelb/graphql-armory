# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      module Controls
        # A schema around `Query` fields the caller writes, for end-to-end examples that need resolvers of their own
        # (reading or writing the context, raising, adding extensions), built fresh on every call:
        #
        #   schema = Controls::AppSchema.example({ "op" => "query Op { greeting }" }, caching: { store: store, release: "r1" }) do |options|
        #     field :greeting, String, null: true, **options
        #     define_method(:greeting) { "hello #{context[:locale]}" }
        #   end
        #
        # `Query` is public (`authorize :none`, covering its fields, and `cache_fields ttl: 60, scope: :public`); the
        # block runs in it and receives the field options `Execution::Next` needs for a field resolved by a method of
        # the type. PersistedQueries is strict over `documents` (id => document). `caching:` are `use
        # GraphQL::Armory::Caching` options; without it caching is not installed. `adapter:` is Authorization's
        # (default: an allowing `Adapters::Substitute`); `before` runs in the schema class before the armory plugins,
        # `after` after them (a `rescue_from` registered after caching, say). `Bases.example` gives the base classes, to
        # build types of your own.
        module AppSchema
          def self.example(documents, caching: nil, adapter: nil, mutation: nil, before: nil, after: nil, &fields)
            options = Schema::NEXT_FIELD_OPTIONS
            query = Class.new(Bases.example.fetch(:object)) do
              graphql_name "Query"
              authorize :none, reason: "test root", covers_fields: true
              cache_fields ttl: 60, scope: :public, reason: "the same for everyone"
              instance_exec(options, &fields) if fields
            end
            adapter ||= Authorization::Adapters::Substitute.new(allow: true)
            manifest = PersistedQueries::Manifest.new(documents, digest: false)
            armory = Armory
            Class.new(GraphQL::Schema) do
              use GraphQL::Execution::Next if defined?(GraphQL::Execution::Next)
              query(query)
              mutation(mutation) if mutation
              class_exec(&before) if before
              use armory::Authorization, adapter: adapter
              use armory::PersistedQueries, store: manifest, strict: true
              use armory::Caching, **caching if caching
              class_exec(&after) if after
            end
          end

          # Base classes with Authorization's and caching's `Base`: `{ argument:, field:, object: }`.
          module Bases
            def self.example
              auth = Authorization::Base
              cache = Caching::Base
              argument = Class.new(GraphQL::Schema::Argument) { include auth }
              field = Class.new(GraphQL::Schema::Field) do
                include auth
                include cache
                argument_class(argument)
              end
              object = Class.new(GraphQL::Schema::Object) do
                include auth
                include cache
                field_class(field)
                default_action :read
              end
              { argument: argument, field: field, object: object }
            end
          end
        end
      end
    end
  end
end
