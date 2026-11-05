# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      class Walk
        # One walk of one query's selected operation. Selections are judged from a work list, never by recursion, and
        # each selection set is judged once per owner type, so a document's depth or its repeated fragment spreads
        # cannot exhaust the stack or multiply the work.
        class Run
          Nodes = GraphQL::Language::Nodes

          TYPENAME = "__typename"
          INTROSPECTION = %w[__schema __type].freeze
          OPERATIONS = { "mutation" => :mutation, "subscription" => :subscription }.freeze

          def initialize(query)
            @query = query
            @types = query.types
            @tally = Tally.new
          end

          def policy
            operation = @query.selected_operation
            return Policy.refused(:no_operation) if operation.nil?
            return Policy.refused(OPERATIONS[operation.operation_type]) if OPERATIONS.key?(operation.operation_type)

            directive = Directives.refusal(@query.document, @types)
            return Policy.refused(directive) if directive

            root = @types.query_root
            return Policy.refused(:unknown_field) if root.nil?

            refusal = catch(:refused) do
              walk(operation.selections, root)
              nil
            end
            refusal ? Policy.refused(refusal) : @tally.policy
          end

          private

          def refuse(reason)
            throw :refused, reason
          end

          def walk(selections, owner)
            pending = [[selections, owner]]
            judged = {}.compare_by_identity
            until pending.empty?
              selections, owner = pending.pop
              next if selections.empty?

              owners = (judged[selections] ||= Set.new)
              next unless owners.add?(owner)

              selections.each { |node| select(node, owner, pending) }
            end
          end

          def select(node, owner, pending)
            case node
            when Nodes::Field
              field(node, owner, pending)
            when Nodes::InlineFragment
              pending << [node.selections, node.type ? condition(node.type.name) : owner]
            when Nodes::FragmentSpread
              definition = @query.fragments[node.name]
              refuse(:invalid_document) if definition.nil?
              pending << [definition.selections, condition(definition.type.name)]
            else
              refuse(:invalid_document)
            end
          end

          # A fragment's type condition becomes the owner of its selections.
          def condition(type_name)
            type = @types.type(type_name)
            refuse(:invalid_document) unless type&.kind&.composite?
            type
          end

          def field(node, owner, pending)
            return if node.name == TYPENAME

            refuse(:introspection) if INTROSPECTION.include?(node.name)

            definitions(owner, node.name).each { |definition| judge(definition) }
              .map { |definition| definition.type.unwrap }.uniq
              .each do |type|
                next unless type.kind.composite?

                tag(type)
                pending << [node.selections, type]
              end
          end

          # The field's definition on its owner and, on an interface, every possible type's own definition of that
          # name: an implementation may override the field with its own declaration, and the most restrictive wins.
          def definitions(owner, name)
            definition = @types.field(owner, name)
            refuse(:unknown_field) if definition.nil?
            return [definition] unless owner.kind.abstract?

            [definition] + @types.possible_types(owner).map do |type|
              @types.field(type, name) || refuse(:unknown_field)
            end
          end

          def judge(definition)
            declaration = definition.respond_to?(:armory_cache) ? definition.armory_cache : nil
            if declaration.nil?
              refuse(:undeclared_field) unless Relay.generated?(definition)
            elsif declaration.forbidden?
              refuse(:forbidden_field)
            else
              @tally.declare(declaration)
            end
            definition
          end

          def tag(type)
            @tally.type(type.graphql_name)
            @types.possible_types(type).each { |possible| @tally.type(possible.graphql_name) } if type.kind.abstract?
          end
        end
      end
    end
  end
end
