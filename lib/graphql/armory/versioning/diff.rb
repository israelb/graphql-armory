# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # What changes between two served versions for a client built against the first, in three buckets:
      #
      # - breaking: a query that worked against `from` can fail against `to` (a type, field, argument, input field, enum
      #   value or union member removed; a required argument or input field added; a type changed; an interface no
      #   longer implemented; a type's kind changed).
      # - dangerous: queries still validate, but a client may see something it does not expect (an enum value, union
      #   member or interface implementation added; a deprecation added; a default value changed; an output made non-null,
      #   which can break a fragment that merges it with a nullable field of the same name).
      # - safe: the rest.
      #
      #   result = GraphQL::Armory::Versioning::Diff.(AppSchema, from: "2024-06-01", to: "2025-01-01")
      #   result.breaking?   # true when a client of 2024-06-01 can break on 2025-01-01
      #   puts result
      #
      # Each version is read through `Versioning.types`, as a client of that version sees it, with `armory_full_schema:
      # true` so Authorization's `visible_when:` hides nothing. Types are compared by name, so twins across the two versions
      # are compared member by member. Directives are not compared. It records no signal.
      class Diff
        BUCKETS = %i[breaking dangerous safe].freeze

        # One change: its bucket, the path of what changed ("Invoice.tags.first") and what happened to it.
        Change = Struct.new(:bucket, :path, :message) do
          def to_s = "#{path}: #{message}"
        end

        # The changes from one version to another, breaking first, each bucket sorted by path.
        class Result
          attr_reader :from, :to, :changes

          def initialize(from:, to:, changes:)
            @from = from
            @to = to
            @changes = changes.sort_by { |change| [BUCKETS.index(change.bucket), change.path, change.message] }.freeze
            freeze
          end

          def breaking = changes.select { |change| change.bucket == :breaking }

          def dangerous = changes.select { |change| change.bucket == :dangerous }

          def safe = changes.select { |change| change.bucket == :safe }

          def breaking? = changes.any? { |change| change.bucket == :breaking }

          def to_s
            lines = ["From #{from} to #{to}:"]
            if changes.empty?
              lines << "No changes."
            else
              BUCKETS.each do |bucket|
                listed = changes.select { |change| change.bucket == bucket }
                next if listed.empty?

                lines.push("", "#{bucket.to_s.capitalize} (#{listed.size}):", *listed.map { |change| "  #{change}" })
              end
            end
            lines.join("\n") << "\n"
          end
        end

        # Answers each version's `View` of a schema. `Reader.new` with nothing reads nothing: it refuses.
        class Reader
          def initialize(schema = nil, context: {})
            @schema = schema
            @context = context
          end

          def view(label)
            raise ConfigurationError, "Diff has no schema to read: use Diff.build(schema) or Diff.(schema, from:, to:)" unless @schema

            versions = Integration.gate(@schema).versions
            raise ConfigurationError, "#{label.inspect} is retired: Diff compares served versions" if versions.fetch(label).retired?

            Versioning.types(@schema, label, context: @context.merge(armory_full_schema: true))
          end

          # Answers the views it is told, per label, and records the labels it was asked about. A label it was not told
          # about is refused.
          class Substitute
            attr_reader :labels

            def initialize
              @views = {}
              @labels = []
            end

            def answer(label, view)
              @views[label] = view
            end

            def view(label)
              @labels << label
              @views.fetch(label) { raise ConfigurationError, "Diff::Reader::Substitute was not told about #{label.inspect}" }
            end
          end
        end

        # Answers the result it is told and records what it was asked: for the rake task's and the matcher's specs.
        class Substitute
          attr_reader :calls

          def initialize(result)
            @result = result
            @calls = []
          end

          def call(schema, from:, to:)
            @calls << [schema, { from: from, to: to }]
            @result
          end
        end

        # Checks the schema is versioned and wires its reader. `context:` is merged into each version's (a user, for an
        # app `visible?` that needs one).
        def self.build(schema, context: {})
          Integration.gate(schema)
          new(Reader.new(schema, context: context))
        end

        def self.call(schema, from:, to:, context: {}) = build(schema, context: context).(from: from, to: to)

        # `new` is inert: with no schema, it refuses instead of answering "no changes".
        def initialize(reader = Reader.new)
          @reader = reader
        end

        def call(from:, to:)
          older = @reader.view(from)
          newer = @reader.view(to)
          changes = []
          Walk.new(older, newer, changes).()
          Result.new(from: from, to: to, changes: changes)
        end

        # Compares two views, type by type. Internal to `Diff`.
        class Walk
          def initialize(old, new, changes)
            @old = old
            @new = new
            @changes = changes
          end

          def call
            old_types = types(@old)
            new_types = types(@new)
            old_types.each do |name, old_type|
              new_type = new_types[name]
              next add(:breaking, name, "type removed") unless new_type

              type(name, old_type, new_type)
            end
            (new_types.keys - old_types.keys).each { |name| add(:safe, name, "type added") }
          end

          private

          def types(view)
            view.all_types.reject { |type| Armory::Definitions.introspection?(type) }.to_h { |type| [type.graphql_name, type] }
          end

          def add(bucket, path, message)
            @changes << Change.new(bucket, path, message)
          end

          def type(name, old_type, new_type)
            if old_type.kind != new_type.kind
              return add(:breaking, name, "kind changed from #{old_type.kind.name} to #{new_type.kind.name}")
            end

            description(name, old_type, new_type)
            case old_type.kind.name
            when "OBJECT", "INTERFACE"
              fields(name, old_type, new_type)
              interfaces(name, old_type, new_type)
            when "UNION" then members(name, old_type, new_type)
            when "ENUM" then values(name, old_type, new_type)
            when "INPUT_OBJECT" then inputs(name, old_type, new_type, input_field: true)
            end
          end

          def fields(type_name, old_type, new_type)
            old_fields = by_name(@old.fields(old_type))
            new_fields = by_name(@new.fields(new_type))
            old_fields.each do |name, old_field|
              path = "#{type_name}.#{name}"
              new_field = new_fields[name]
              next add(:breaking, path, "field removed") unless new_field

              type_change(path, old_field.type, new_field.type, output: true)
              deprecation(path, old_field, new_field)
              description(path, old_field, new_field)
              inputs(path, old_field, new_field, input_field: false)
            end
            (new_fields.keys - old_fields.keys).each { |name| add(:safe, "#{type_name}.#{name}", "field added") }
          end

          # Arguments of a field, or input fields of an input object.
          def inputs(owner_path, old_owner, new_owner, input_field:)
            noun = input_field ? "input field" : "argument"
            old_inputs = by_name(@old.arguments(old_owner))
            new_inputs = by_name(@new.arguments(new_owner))
            old_inputs.each do |name, old_input|
              path = "#{owner_path}.#{name}"
              new_input = new_inputs[name]
              next add(:breaking, path, "#{noun} removed") unless new_input

              input(path, old_input, new_input)
            end
            (new_inputs.keys - old_inputs.keys).each do |name|
              required = required?(new_inputs[name])
              add(required ? :breaking : :safe, "#{owner_path}.#{name}", required ? "required #{noun} added" : "#{noun} added")
            end
          end

          def input(path, old_input, new_input)
            bucket = type_change(path, old_input.type, new_input.type, output: false)
            if bucket != :breaking && !required?(old_input) && required?(new_input)
              add(:breaking, path, "now required: its default value was removed")
            elsif bucket != :breaking && default_changed?(old_input, new_input)
              add(:dangerous, path, default_message(old_input, new_input))
            end
            deprecation(path, old_input, new_input)
            description(path, old_input, new_input)
          end

          def interfaces(type_name, old_type, new_type)
            old_names = @old.interfaces(old_type).map(&:graphql_name)
            new_names = @new.interfaces(new_type).map(&:graphql_name)
            (old_names - new_names).sort.each { |name| add(:breaking, type_name, "no longer implements #{name}") }
            (new_names - old_names).sort.each { |name| add(:dangerous, type_name, "now implements #{name}") }
          end

          def members(type_name, old_type, new_type)
            old_names = @old.possible_types(old_type).map(&:graphql_name)
            new_names = @new.possible_types(new_type).map(&:graphql_name)
            (old_names - new_names).sort.each { |name| add(:breaking, type_name, "member #{name} removed") }
            (new_names - old_names).sort.each { |name| add(:dangerous, type_name, "member #{name} added") }
          end

          def values(type_name, old_type, new_type)
            old_values = by_name(@old.enum_values(old_type))
            new_values = by_name(@new.enum_values(new_type))
            old_values.each do |name, old_value|
              path = "#{type_name}.#{name}"
              new_value = new_values[name]
              next add(:breaking, path, "value removed") unless new_value

              deprecation(path, old_value, new_value)
              description(path, old_value, new_value)
            end
            (new_values.keys - old_values.keys).each { |name| add(:dangerous, "#{type_name}.#{name}", "value added") }
          end

          # Records a type change and answers its bucket, or nil when the type is the same.
          def type_change(path, old_type, new_type, output:)
            bucket = output ? output_change(old_type, new_type) : input_change(old_type, new_type)
            return if bucket == :same

            add(bucket, path, "type changed from #{old_type.to_type_signature} to #{new_type.to_type_signature}")
            bucket
          end

          # A client reading an output copes with it becoming non-null, but not with it becoming nullable. Becoming non-null
          # is still dangerous: two fields of one response name must have the same shape to merge (GraphQL spec, "Field
          # Selection Merging"), so a query selecting it beside a nullable field of another type stops validating.
          def output_change(old_type, new_type)
            if old_type.non_null?
              return :breaking unless new_type.non_null?

              output_change(old_type.of_type, new_type.of_type)
            elsif new_type.non_null?
              stricter(output_change(old_type, new_type.of_type))
            else
              wrapped_change(old_type, new_type) { |old_item, new_item| output_change(old_item, new_item) }
            end
          end

          # A client sending an input copes with it becoming nullable (a `T!` variable is allowed where `T` is expected,
          # "All Variable Usages Are Allowed"), but not with it becoming non-null.
          def input_change(old_type, new_type)
            if new_type.non_null?
              return :breaking unless old_type.non_null?

              input_change(old_type.of_type, new_type.of_type)
            elsif old_type.non_null?
              looser(input_change(old_type.of_type, new_type))
            else
              wrapped_change(old_type, new_type) { |old_item, new_item| input_change(old_item, new_item) }
            end
          end

          def wrapped_change(old_type, new_type)
            if old_type.list? || new_type.list?
              return :breaking unless old_type.list? && new_type.list?

              yield(old_type.of_type, new_type.of_type)
            else
              old_type.graphql_name == new_type.graphql_name ? :same : :breaking
            end
          end

          def stricter(bucket) = bucket == :same || bucket == :safe ? :dangerous : bucket

          def looser(bucket) = bucket == :same ? :safe : bucket

          def required?(input) = input.type.non_null? && !input.default_value?

          def default_changed?(old_input, new_input)
            old_input.default_value? != new_input.default_value? ||
              (old_input.default_value? && old_input.default_value != new_input.default_value)
          end

          def default_message(old_input, new_input)
            return "default value #{new_input.default_value.inspect} added" unless old_input.default_value?
            return "default value #{old_input.default_value.inspect} removed" unless new_input.default_value?

            "default value changed from #{old_input.default_value.inspect} to #{new_input.default_value.inspect}"
          end

          def deprecation(path, old_member, new_member)
            old_reason = deprecation_reason(old_member)
            new_reason = deprecation_reason(new_member)
            if old_reason.nil? && new_reason
              add(:dangerous, path, "deprecated: #{new_reason}")
            elsif old_reason && new_reason.nil?
              add(:safe, path, "no longer deprecated")
            elsif old_reason != new_reason
              add(:safe, path, "deprecation reason changed")
            end
          end

          def deprecation_reason(member) = member.respond_to?(:deprecation_reason) ? member.deprecation_reason : nil

          def description(path, old_member, new_member)
            add(:safe, path, "description changed") if old_member.description != new_member.description
          end

          def by_name(members) = members.to_h { |member| [member.graphql_name, member] }
        end
        private_constant :Walk
      end
    end
  end
end
