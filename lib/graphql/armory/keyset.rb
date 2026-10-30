# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    # A connection that pages an ActiveRecord relation by the values of its ordering columns instead of OFFSET,
    # so rows inserted or deleted between pages neither skip nor repeat items. Return it from a resolver:
    #
    #   def invoices
    #     GraphQL::Armory::Keyset.build(Invoice.order(created_at: :desc))
    #   end
    #
    # A cursor holds the row's ordering values. Base64 cursors would let a client read them and forge them to
    # search a column it cannot see, so the schema's default encoder is refused unless `plain_cursors: true`.
    class Keyset < GraphQL::Pagination::Connection
      class ConfigurationError < Armory::Error; end

      CURSOR_VERSION = 1
      PAGEABLE_TYPES = %i[integer string text decimal datetime date boolean uuid].freeze

      Column = Struct.new(:name, :direction, :attribute, :type, keyword_init: true)

      # Reads what a relation is ordered by, adds the primary key as the tie-breaker, and refuses what it cannot page.
      module Ordering
        def self.call(relation)
          refuse("a limit") if relation.limit_value
          refuse("an offset") if relation.offset_value
          refuse("a group") if relation.group_values.any?
          refuse("a select") if relation.select_values.any?

          columns = relation.order_values.map { |order| column(relation.klass, order) }.uniq(&:name)
          primary_key = Array(relation.klass.primary_key)
          refuse("a model without a primary key") if primary_key.empty?

          direction = columns.last&.direction || :asc
          (primary_key - columns.map(&:name)).each { |name| columns << column_named(relation.klass, name, direction) }
          columns.freeze
        end

        def self.column(klass, order)
          direction = { Arel::Nodes::Ascending => :asc, Arel::Nodes::Descending => :desc }[order.class]
          attribute = order.expr if direction
          refuse("an order that is not a plain column: #{order.class}") unless attribute.is_a?(Arel::Attributes::Attribute)
          refuse("an order on another table: #{attribute.relation.name}") unless attribute.relation.name == klass.table_name

          column_named(klass, attribute.name.to_s, direction)
        end

        def self.column_named(klass, name, direction)
          definition = klass.columns_hash[name]
          refuse("an order on an unknown column: #{name}") if definition.nil?
          refuse("an order on a nullable column: #{name}") if definition.null && klass.primary_key != name

          type = klass.type_for_attribute(name)
          refuse("an order on a #{type.type} column: #{name}") unless PAGEABLE_TYPES.include?(type.type)

          Column.new(name: name, direction: direction, attribute: klass.arel_table[name], type: type)
        end

        def self.refuse(what)
          raise ConfigurationError, "a keyset connection cannot page #{what}"
        end
      end

      attr_reader :columns

      # Checks the relation and its ordering; resolvers go through here.
      def self.build(relation, plain_cursors: false)
        raise ConfigurationError, "plain_cursors: must be true or false, got #{plain_cursors.inspect}" unless [true, false].include?(plain_cursors)
        raise ConfigurationError, "a keyset connection needs an ActiveRecord relation, got #{relation.class}" unless relation.respond_to?(:order_values)

        new(relation, columns: Ordering.(relation), plain_cursors: plain_cursors)
      end

      # `new` is inert: with no relation it has no rows, no pages and no cursors.
      def initialize(items = nil, columns: [], plain_cursors: false, **options)
        super(items, **options)
        @columns = columns
        @plain_cursors = plain_cursors
      end

      # The same connection over the relation the block answers: how a type's scope reaches the rows.
      def rescoped
        return self if items.nil?

        self.class.build(yield(items), plain_cursors: @plain_cursors)
      end

      def nodes
        load_page
        @nodes
      end

      def has_next_page
        return false if items.nil?

        load_page
        return @more if !@backward && before.nil?
        return false if @backward && before.nil?

        anchor = @nodes.last
        anchor ? beyond?(key_of(anchor), :after) : beyond?(@before_key, :after, inclusive: true)
      end

      def has_previous_page
        return false if items.nil?

        load_page
        return @more if @backward && after.nil?
        return false if !@backward && after.nil?

        anchor = @nodes.first
        anchor ? beyond?(key_of(anchor), :before) : beyond?(@after_key, :before, inclusive: true)
      end

      def cursor_for(item)
        return nil if items.nil?

        refuse_plain_cursors
        values = columns.map { |column| dump(column.type.serialize(item[column.name])) }
        encode(JSON.generate("v" => CURSOR_VERSION, "o" => fingerprint, "k" => values))
      end

      private

      def load_page
        return if defined?(@nodes)

        return @nodes = [] if items.nil?

        refuse_plain_cursors
        raise GraphQL::ExecutionError, "first and last cannot be used together" if first_value && last_value

        @after_key = after && key_from(after)
        @before_key = before && key_from(before)
        @backward = !last_value.nil?
        limit = @backward ? last : first

        relation = items
        relation = relation.where(condition(@after_key, :after)) if @after_key
        relation = relation.where(condition(@before_key, :before)) if @before_key
        relation = relation.reorder(columns.map { |column| arel_order(column) })
        relation = relation.limit(limit + 1) if limit

        rows = relation.to_a
        @more = !limit.nil? && rows.size > limit
        rows = rows.first(limit) if limit
        @nodes = @backward ? rows.reverse : rows
      end

      def refuse_plain_cursors
        return if @plain_cursors

        encoder = context&.schema&.cursor_encoder
        return unless encoder.nil? || encoder == GraphQL::Schema::Base64Encoder

        raise ConfigurationError,
              "a keyset cursor holds the row's ordering values: set an encrypting cursor_encoder on the schema " \
              "(GraphQL::Armory::Encoder), or pass plain_cursors: true if those values are not secret"
      end

      def arel_order(column)
        forward = column.direction == :asc
        forward = !forward if @backward
        forward ? column.attribute.asc : column.attribute.desc
      end

      def beyond?(key, side, inclusive: false)
        items.where(condition(key, side, inclusive: inclusive)).exists?
      end

      # (a > x) OR (a = x AND b > y) OR ...: the rows past `key` on `side`, for any mix of directions.
      def condition(key, side, inclusive: false)
        pairs = columns.zip(key)
        branches = pairs.each_index.map do |index|
          column, value = pairs[index]
          ascending = (column.direction == :asc) == (side == :after)
          past = ascending ? column.attribute.gt(value) : column.attribute.lt(value)
          pairs.first(index).reverse_each.inject(past) { |node, (earlier, equal)| earlier.attribute.eq(equal).and(node) }
        end
        branches << pairs.map { |column, value| column.attribute.eq(value) }.inject(:and) if inclusive
        branches.inject(:or)
      end

      def key_of(record)
        columns.map { |column| record[column.name] }
      end

      def fingerprint
        columns.map { |column| "#{column.attribute.relation.name}.#{column.name}:#{column.direction}" }.join(",")
      end

      def dump(value)
        case value
        when BigDecimal then value.to_s("F")
        when Date then value.iso8601
        else value.respond_to?(:getutc) ? value.getutc.iso8601(9) : value
        end
      end

      # Every cursor that cannot be honoured answers the same error, whatever is wrong with it.
      def key_from(cursor)
        payload = JSON.parse(decoded(cursor))
        raise Encoder::InvalidError unless payload.is_a?(Hash) && payload["v"] == CURSOR_VERSION && payload["o"] == fingerprint

        values = payload["k"]
        raise Encoder::InvalidError unless values.is_a?(Array) && values.size == columns.size

        columns.zip(values).map { |column, value| load_value(column, value) }
      rescue JSON::ParserError, EncodingError, ActiveModel::RangeError
        raise Encoder::InvalidError
      end

      def decoded(cursor)
        decode(cursor).dup.force_encoding(Encoding::UTF_8).tap { |text| raise Encoder::InvalidError unless text.valid_encoding? }
      rescue GraphQL::ExecutionError
        raise Encoder::InvalidError
      end

      def load_value(column, value)
        scalar = [String, Integer, TrueClass, FalseClass].any? { |kind| value.is_a?(kind) }
        raise Encoder::InvalidError if !scalar || (value.is_a?(String) && value.include?("\0"))

        cast = column.type.cast(value)
        raise Encoder::InvalidError if cast.nil?

        column.type.serialize(cast)
        cast
      end
    end
  end
end

require "graphql/armory/keyset/controls"
