# frozen_string_literal: true

require "set"
require "graphql/armory/caching/gate/admission"
require "graphql/armory/caching/gate/store_check"
require "graphql/armory/caching/gate/signals"

module GraphQL
  module Armory
    module Caching
      # Decides, per `multiplex` call, which queries are answered from the store, which run and may be stored, and
      # which run uncached (docs/response-caching.md 4.2):
      #
      #   decisions = gate.(queries, engine: :interpreter)   # one Decision per query, in order
      #   gate.store(query, decision, result)                # after a miss ran: :stored, or the reason it was not
      #
      # `Gate.new` is inert: its walk refuses every operation, so every query runs uncached and nothing reaches the
      # store. `Gate.build` wires the real walk, keyer, codec, charge and store from the `use` options.
      class Gate
        ENGINES = %i[interpreter next].freeze

        # graphql-ruby's own context keys: their values are fixed by the request or are key components (4.4).
        MACHINERY_KEYS = [
          *GraphQL::Query::Context::RUNTIME_METADATA_KEYS,
          :trace, :tracers, :trace_mode, :dataloader, :backtrace, :visibility_profile, :__graphql_execute_next,
          # The APM tracers' transaction name settings (lib/graphql/tracing/*).
          :set_appsignal_action_name, :set_new_relic_transaction_name, :set_scout_transaction_name,
          :set_sentry_transaction_name, :tracing_fallback_transaction_name
        ].freeze

        DEFAULT_ON_STORE_ERROR = ->(error, _query) { warn("graphql-armory cache store failed, query runs uncached: #{error.class}") }

        # Wires the real dependencies from the checked `use` options (`Integration::Settings#to_h`). `digester:` is the
        # one the installer built: `purge` digests tags with it, so the gate never builds its own. The options only the
        # audit reads (`own_checks:`, `sinks:`, ...) are ignored here.
        def self.build(schema, store:, digester:, telemetry:, release:, encoder: nil, viewer: nil, viewer_id: Viewer::DEFAULT_ID,
                       anonymous: :uncacheable, anonymous_reason: nil, vary: {}, max_ttl: 3600, max_viewer_ttl: 300,
                       max_entry_bytes: 262_144, neutral_keys: {}, context_methods: {}, extensions: false, on_store_error: nil, **_audit_only)
          check_store_ttl(store, max_ttl)
          keyer = Keyer.build(release: release, digester: digester, viewer: viewer, viewer_id: viewer_id, anonymous: anonymous,
                              anonymous_reason: anonymous_reason, vary: vary)
          new(store: store, walk: Walk.build, keyer: keyer, codec: encoder ? Codec.build(encoder: encoder) : Codec.new,
              charge: Charge.build(schema), telemetry: telemetry, digester: digester, max_ttl: max_ttl, max_viewer_ttl: max_viewer_ttl,
              max_entry_bytes: max_entry_bytes, viewer_key: keyer.viewer_key, vary_keys: keyer.vary_context_keys,
              neutral_keys: neutral_keys, context_methods: context_methods, recorded_cost: ->(query) { Charge.recorded_cost(query) },
              extensions: extensions, on_store_error: on_store_error)
        end

        # A store prunes purge marks older than its own `max_ttl`: an entry living longer than that could outlive the
        # mark that purged it and be served again.
        def self.check_store_ttl(store, max_ttl)
          return unless store.respond_to?(:max_ttl) && store.max_ttl.is_a?(Integer)
          return if store.max_ttl >= max_ttl

          raise ConfigurationError, "max_ttl: #{max_ttl} exceeds the store's max_ttl: #{store.max_ttl}, after which it prunes purge marks: " \
                                    "build the store with max_ttl: #{max_ttl} or more"
        end
        private_class_method :check_store_ttl

        # - `store`, `walk`, `keyer`, `codec`, `charge`, `telemetry`, `digester`: the dependencies (Null by default).
        #   `codec` defaults to `Codec.new`, the plain JSON codec, read when the gate is built, never at load time.
        # - `max_ttl`, `max_viewer_ttl` (seconds): a stored TTL never exceeds them, whatever the declarations say.
        # - `max_entry_bytes`: a larger sealed entry is not stored.
        # - `viewer_key`: the `viewer:` context key; it covers reads of that key in `:viewer` runs only.
        # - `vary_keys`: the `vary:` entries given as context keys; their whole value is in the key, so they cover.
        # - `neutral_keys`: the app's answer-neutral keys (`{ request_id: "logging only" }`, or an Array).
        # - `context_methods`: the public methods the app's context class adds, each with a reason. A query whose
        #   context class adds a method not named here runs uncached (`:context_method`): it reads unrecorded.
        # - `recorded_cost`: a callable answering the Points the query's run was charged (an Integer), or nil when it
        #   recorded none; nil (the default) means no Points limiter. When the charge reports a limiter for the query
        #   (`charge.limited?(query)`, or always for a charge without `limited?`), a miss without a cost is not stored
        #   and an entry without a cost is never served: a hit would be free.
        # - `extensions`: true adds `"cache" => { "hit" => true, "age" => n }` to a hit's response.
        # - `on_store_error`: called with `(error, query)` when the store raises; the query runs uncached.
        # - `clock`: a callable answering the store clock in Integer milliseconds, for `:run_too_long`. Defaults to
        #   `store.now` when the store has one; without it, the store's own refusal of an expired write bounds the run.
        def initialize(store: Store::Null.new, walk: Walk::Null.new, keyer: Keyer::Null.new, codec: Codec.new, charge: Charge::Null.new,
                       telemetry: Telemetry.new, digester: Digester.new, max_ttl: 3600, max_viewer_ttl: 300, max_entry_bytes: 262_144,
                       viewer_key: nil, vary_keys: [], neutral_keys: {}, context_methods: {}, recorded_cost: nil, extensions: false,
                       on_store_error: nil, clock: nil)
          positive!(:max_ttl, max_ttl)
          positive!(:max_viewer_ttl, max_viewer_ttl)
          positive!(:max_entry_bytes, max_entry_bytes)
          raise ConfigurationError, "viewer_key: must be a context key (Symbol or String) or nil" unless viewer_key.nil? || context_key?(viewer_key)
          raise ConfigurationError, "vary_keys: must be an Array of context keys (Symbols or Strings)" unless vary_keys.is_a?(Array) && vary_keys.all? { |key| context_key?(key) }

          neutral = neutral_keys.is_a?(Hash) ? neutral_keys.keys : neutral_keys
          raise ConfigurationError, "neutral_keys: must be a Hash of context key => reason" unless neutral.is_a?(Array) && neutral.all? { |key| context_key?(key) }

          declared = context_methods.is_a?(Hash) ? context_methods.keys : context_methods
          raise ConfigurationError, "context_methods: must be a Hash of method name => reason" unless declared.is_a?(Array) && declared.all? { |name| context_key?(name) }

          callable!(:recorded_cost, recorded_cost)
          callable!(:on_store_error, on_store_error)
          callable!(:clock, clock)
          raise ConfigurationError, "extensions: must be true or false" unless [true, false].include?(extensions)

          @store = store
          @walk = walk
          @keyer = keyer
          @keyer_takes_engine = takes_engine?(keyer)
          @codec = codec
          @charge = charge
          @digester = digester
          @signals = Signals.new(telemetry)
          @max_ttl = max_ttl
          @max_viewer_ttl = max_viewer_ttl
          @max_entry_bytes = max_entry_bytes
          @recorded_cost = recorded_cost
          @context_methods = declared.map(&:to_sym).freeze
          @undeclared = {}.compare_by_identity
          @undeclared_lock = Mutex.new
          @extensions = extensions
          @on_store_error = on_store_error || DEFAULT_ON_STORE_ERROR
          @clock = clock || (store.respond_to?(:now) ? -> { store.now } : nil)

          always = [*MACHINERY_KEYS, *Admission::ABSENT_KEYS.keys, *neutral, *vary_keys]
          @covered = {
            public: Set.new(always).freeze,
            viewer: Set.new(always + [viewer_key].compact).freeze
          }.freeze
        end

        # One Decision per query, in order: hit (answered: `RecordKeys.hit_result` holds its Result), miss (run it,
        # then `store`), or pass (run it uncached). `engine` is `:interpreter` or `:next`: it is in the key.
        def call(queries, engine:)
          raise ArgumentError, "engine: must be one of #{ENGINES.inspect}, got #{engine.inspect}" unless ENGINES.include?(engine)

          mutation = queries.any? { |query| Admission.mutation?(query) }
          queries.map { |query| decide(query, engine, mutation) }
        end

        # After a miss ran: stores its answer when every store-time check holds. Answers `:stored` or the reason it
        # was not stored; for a hit or a pass, answers without storing anything.
        def store(query, decision, result)
          return decision.pass? ? decision.reason : :hit unless decision.miss?

          key = decision.key
          lookup = decision.lookup
          scope = key.scope
          reason, context_key = refusal(query, decision, values_of(result))
          return skip(query, reason, scope, context_key) if reason

          ttl = capped_ttl(decision.policy.ttl, scope)
          costed = costed?(query)
          cost = costed ? @recorded_cost.call(query) : nil
          return skip(query, :cost_unknown, scope) if costed && !(cost.is_a?(Integer) && cost >= 0)
          return skip(query, :run_too_long, scope) if run_too_long?(lookup)

          tags = (decision.policy.tags.map { |tag| @digester.(tag) } + [key.viewer_tag].compact).uniq.sort
          entry = Entry.new(key: key.digest, data: values_of(result)["data"], stored_at: lookup.now, ttl: ttl, scope: scope,
                            seq: lookup.seq, epoch: lookup.epoch, tags: tags, cost: cost)
          blob = @codec.encode(entry, key.digest)
          return skip(query, :too_large, scope) if blob.bytesize > @max_entry_bytes

          write(query, key, blob, entry, scope)
        end

        private

        def decide(query, engine, mutation)
          reason = Admission.refusal(query, mutation_in_call: mutation)
          return pass(query, reason) if reason
          return pass(query, :context_method) unless undeclared_methods(query.context.class).empty?

          policy = @walk.(query)
          return pass(query, refusal_reason(policy)) unless policy.is_a?(Policy) && policy.cacheable?

          key = @keyer_takes_engine ? @keyer.(query, policy, engine: engine) : @keyer.(query, policy)
          return pass(query, refusal_reason(key)) unless key.is_a?(Key)
          # The key decides who an answer is served to: it must be scoped like the policy that allows it.
          return pass(query, :key_scope, policy.scope) unless key.scope == policy.scope

          lookup = look_up(query, key)
          return Decision.pass(:store_failed) unless lookup
          return Decision.miss(key, policy, lookup) unless lookup.found?

          entry, rejection = open(query, lookup, key)
          if rejection
            @signals.rejected(query, rejection)
            return Decision.miss(key, policy, lookup)
          end

          hit(query, entry, lookup)
        end

        def pass(query, reason, scope = nil)
          @signals.skipped(query, reason, scope: scope)
          Decision.pass(reason)
        end

        def refusal_reason(answer)
          answer.is_a?(Policy) && answer.reason.is_a?(Symbol) ? answer.reason : :unconfigured
        end

        # One round trip; nil when the store failed (reported).
        def look_up(query, key)
          lookup = @store.lookup(key.digest)
          raise TypeError, "the store's lookup answered a #{lookup.class}, not a Lookup" unless lookup.is_a?(Lookup)

          lookup
        rescue StandardError => error
          failed(query, :lookup, error, key.scope)
          nil
        end

        # The entry, or the reason it must not be served. A poisoned blob is a miss, whatever the codec raised.
        def open(query, lookup, key)
          entry = @codec.decode(lookup.blob, key.digest)
          [entry, rejection(query, entry, lookup, key)]
        rescue Entry::Rejected => rejected
          [nil, rejected.reason]
        rescue StandardError
          [nil, :format]
        end

        def rejection(query, entry, lookup, key)
          return :key unless entry.key == key.digest && entry.scope == key.scope
          # A lost meta record (another epoch), or a replica behind the entry's seq: everything older is purged.
          return :epoch unless entry.epoch == lookup.epoch && entry.seq <= lookup.seq
          return :expired if entry.expired?(lookup.now)
          # The store keeps the tags beside the sealed blob only to read their marks; the sealed list is the truth.
          return :tags unless entry.tags == lookup.tags.uniq.sort
          return :purged if lookup.marks.any? { |_tag, mark| mark > entry.seq }
          return :cost_unknown if entry.cost.nil? && costed?(query)

          nil
        end

        def hit(query, entry, lookup)
          refusal = @charge.(query, entry.cost)
          result = refusal.nil? ? cached_result(query, entry, lookup) : refusal_result(query, refusal)
          RecordKeys.hit_result!(query.context, result)
          @signals.hit(query, entry, lookup.now, limited: !refusal.nil?)
          Decision.hit(entry)
        end

        def cached_result(query, entry, lookup)
          values = { "data" => entry.data }
          extensions = query.context.namespace?(:__query_result_extensions__) ? query.context.response_extensions.dup : {}
          extensions["cache"] = { "hit" => true, "age" => entry.age(lookup.now) } if @extensions
          values["extensions"] = extensions unless extensions.empty?
          GraphQL::Query::Result.new(query: query, values: values)
        end

        # The limiter's refusal, in the shape the charge answered it: a Result, a response Hash, or the error itself.
        def refusal_result(query, refusal)
          case refusal
          when GraphQL::Query::Result then refusal
          when Hash then GraphQL::Query::Result.new(query: query, values: refusal)
          when GraphQL::ExecutionError
            values = { "errors" => [refusal.to_h] }
            values["extensions"] = query.context.response_extensions.dup if query.context.namespace?(:__query_result_extensions__)
            GraphQL::Query::Result.new(query: query, values: values)
          else
            raise ArgumentError, "the charge answered a #{refusal.class}: expected nil, a Result, a response Hash or a GraphQL::ExecutionError"
          end
        end

        def values_of(result)
          values = result.respond_to?(:to_h) ? result.to_h : result
          values.is_a?(Hash) ? values : {}
        end

        # Every store-time check of 4.2 step 8 that reads the run, in order. Answers `[reason, key name]` or nil.
        def refusal(query, decision, values)
          reason = StoreCheck.response(values)
          return [reason] if reason
          return [:rescued] if RecordKeys.rescued?(query.context)

          recorder = RecordKeys.recorder(query.context) || Recorder::Null.new
          checked = StoreCheck.recorder(recorder, @covered.fetch(decision.key.scope))
          return checked if checked
          return [:policy_consulted] if decision.key.scope == :public && RecordKeys.viewer_dependent?(query.context)

          nil
        end

        def capped_ttl(ttl, scope)
          ttl = [ttl, @max_ttl].min
          scope == :viewer ? [ttl, @max_viewer_ttl].min : ttl
        end

        # Purge marks older than max_ttl may already be pruned: a write that long after its lookup could undo one.
        def run_too_long?(lookup)
          now = @clock&.call
          now.is_a?(Integer) && now - lookup.now > @max_ttl * 1000
        end

        def write(query, key, blob, entry, scope)
          written = @store.write(key.digest, blob, tags: entry.tags, ttl: entry.ttl, seq: entry.seq, epoch: entry.epoch, stored_at: entry.stored_at)
          return skip(query, :write_refused, scope) unless written == true

          @signals.stored(query, scope, entry.ttl)
          :stored
        rescue StandardError => error
          failed(query, :write, error, scope)
          :store_failed
        end

        def skip(query, reason, scope, key = nil)
          @signals.skipped(query, reason, scope: scope, key: key)
          reason
        end

        def failed(query, operation, error, scope)
          @signals.store_failed(query, operation, error, scope: scope)
          begin
            @on_store_error.call(error, query)
          rescue StandardError => handler_error
            warn("graphql-armory cache on_store_error raised, query runs uncached: #{handler_error.class}")
          end
        end

        # Whether this query's hits must be charged a recorded cost. Looked up per query: Points may be `use`d after
        # Caching, and a subclass may add its own limiter.
        def costed?(query)
          return false unless @recorded_cost

          !@charge.respond_to?(:limited?) || @charge.limited?(query)
        end

        # The added public methods of a context class the app did not declare, memoized per class.
        def undeclared_methods(klass)
          @undeclared.fetch(klass) do
            found = klass.is_a?(Class) && klass <= GraphQL::Query::Context ? ContextMethods.undeclared(klass, @context_methods) : []
            @undeclared_lock.synchronize { @undeclared[klass] = found.freeze }
          end
        end

        # Whether the keyer's `call` takes the engine: a keyword `engine:`, `**`, or `*arguments` (a Substitute).
        def takes_engine?(keyer)
          callable = keyer.is_a?(Proc) || keyer.is_a?(Method) ? keyer : keyer.method(:call)
          callable.parameters.any? { |type, name| (%i[key keyreq].include?(type) && name == :engine) || %i[keyrest rest].include?(type) }
        rescue NameError
          false
        end

        def context_key?(key)
          key.is_a?(Symbol) || key.is_a?(String)
        end

        def positive!(name, value)
          raise ConfigurationError, "#{name}: must be a positive Integer, got #{value.class}" unless value.is_a?(Integer) && value.positive?
        end

        def callable!(name, value)
          raise ConfigurationError, "#{name}: must be a callable or nil, got #{value.class}" unless value.nil? || value.respond_to?(:call)
        end
      end
    end
  end
end
