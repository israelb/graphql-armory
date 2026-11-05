# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Who a `:viewer` answer belongs to: the principal the `viewer:` context key holds, as `[class name, id]`, so
      # `User 7` and `AdminUser 7` never share an entry.
      #
      #   viewer = Viewer.build(key: :current_user)                                  # id: principal.id
      #   viewer = Viewer.build(key: :current_account, id: ->(account) { account.uuid })
      #   viewer = Viewer.build(key: :current_user, anonymous: :shared, anonymous_reason: "the storefront is the same for every guest")
      #   viewer.(context)   # => Identity(component:, tag:), or Policy.refused(:anonymous | :viewer_unconfigured)
      #
      # A request whose key is absent, nil or false is anonymous. `anonymous: :uncacheable` (the default) refuses it;
      # `:shared` gives every anonymous request of one form one entry per key. The component keeps the three forms apart
      # (a resolver can tell an absent key from a nil one), and all three carry the one anonymous purge tag.
      #
      # `new` is inert: with no key it refuses every request as `:viewer_unconfigured`.
      class Viewer
        ANONYMOUS = %i[uncacheable shared].freeze

        # The default `viewer_id:`.
        DEFAULT_ID = lambda do |principal|
          raise ConfigurationError, "the viewer (a #{principal.class}) has no id: pass viewer_id: to answer it" unless principal.respond_to?(:id)

          principal.id
        end

        # `component` enters the key; `tag` is the purge tag in clear (`Tags.viewer` or `Tags::ANONYMOUS`), which the
        # keyer digests before it leaves.
        Identity = Struct.new(:component, :tag, keyword_init: true)

        # Validates `use`'s `viewer:`, `viewer_id:`, `anonymous:` and `anonymous_reason:`.
        def self.build(key: nil, id: DEFAULT_ID, anonymous: :uncacheable, anonymous_reason: nil)
          unless key.nil? || ((key.is_a?(Symbol) || key.is_a?(String)) && !key.to_s.empty?)
            raise ConfigurationError, "viewer: must be the context key (a Symbol or String) that holds the principal, or nil"
          end
          unless id.respond_to?(:call) && [1, -1, -2].include?(arity(id))
            raise ConfigurationError, "viewer_id: must be a callable taking the principal and answering its id"
          end
          raise ConfigurationError, "anonymous: must be :uncacheable or :shared, got #{anonymous.inspect}" unless ANONYMOUS.include?(anonymous)

          reason = anonymous_reason.is_a?(String) && !anonymous_reason.strip.empty?
          if anonymous == :shared && !reason
            raise ConfigurationError, "anonymous: :shared needs anonymous_reason: (why every anonymous request may see one answer)"
          end
          raise ConfigurationError, "anonymous_reason: only goes with anonymous: :shared" if anonymous == :uncacheable && !anonymous_reason.nil?

          new(key: key, id: id, anonymous: anonymous)
        end

        def self.arity(callable)
          callable.respond_to?(:arity) ? callable.arity : callable.method(:call).arity
        end
        private_class_method :arity

        attr_reader :key

        def initialize(key: nil, id: DEFAULT_ID, anonymous: :uncacheable)
          @key = key
          @id = id
          @anonymous = anonymous
        end

        def call(context)
          return Policy.refused(:viewer_unconfigured) if @key.nil?

          principal = context[@key]
          return anonymous(context, principal) if principal.nil? || false.equal?(principal)

          class_name, id = identify(principal)
          Identity.new(component: [class_name, id], tag: Tags.viewer(class_name, id))
        end

        # `[class name, id]`; raises `ConfigurationError` for a principal of an anonymous class or an id that is not a
        # non-empty String or an Integer. The message never holds the id.
        def identify(principal)
          class_name = principal.class.name
          raise ConfigurationError, "the viewer is an instance of an anonymous class: name its class, so its answers have an owner" if class_name.nil? || class_name.empty?

          id = @id.call(principal)
          unless id.is_a?(Integer) || (id.is_a?(String) && !id.empty?)
            raise ConfigurationError, "viewer_id: answered a #{id.class} for a #{class_name}: it must answer a non-empty String or an Integer"
          end

          [class_name, id]
        end

        # The purge tag in clear of a principal, or of every anonymous request (`:anonymous`).
        def tag(principal)
          return Tags::ANONYMOUS if :anonymous.equal?(principal)

          Tags.viewer(*identify(principal))
        end

        def inspect = "#<#{self.class.name} key=#{@key.inspect} anonymous=#{@anonymous.inspect}>"

        private

        def anonymous(context, principal)
          return Policy.refused(:anonymous) unless @anonymous == :shared

          form = if !context.key?(@key) then "absent"
                 elsif principal.nil? then "nil"
                 else "false"
                 end
          Identity.new(component: "anonymous:#{form}", tag: Tags::ANONYMOUS)
        end
      end
    end
  end
end
