# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # What a refusal tells the client: the code, never a value it sent.
        REFUSALS = {
          viewer_cap: ["Too many subscriptions", "SUBSCRIPTION_LIMIT"],
          topic_cap: ["Too many subscriptions", "SUBSCRIPTION_LIMIT"]
        }.freeze
        REFUSED = ["Subscription refused", "SUBSCRIPTION_REFUSED"].freeze

        # Called by graphql-ruby when a subscription operation finished (both engines): stores the subscription, or
        # refuses it with a GraphQL error and stores nothing. Nothing from the context is kept but the viewer's id and
        # the `context_keys:` values.
        def write_subscription(query, events)
          context = query.context
          raise RefusedError.new("subscription_id was set before the subscription was written", reason: :client_id) unless context[:subscription_id].nil?

          now = now_ms
          viewer = @settings.viewer
          viewer_id = viewer.id(context)
          viewer_digest = viewer_id ? hex_mac(viewer_id, VIEWER_PURPOSE) : Record::ANONYMOUS
          cap_digest = viewer_id ? viewer_digest : hex_mac(viewer.cap_subject(context), CAP_PURPOSE)
          id = build_id
          record = Record.new(
            id: id, document: document_of(query), operation_name: query.operation_name, variables: dump_variables(query),
            operation_id: persisted_id(context), raw_query: context[:armory_allow_raw_query] == true, version: version_label(context),
            visibility_profile: visibility_profile(context), engine: context[:__graphql_execute_next] == true ? :next : :interpreter,
            viewer_id: viewer_id, viewer_digest: viewer_digest, context: stored_context(context), events: digested(query, events),
            created_at: now, expires_at: now + @settings.max_lifetime
          )
          store_record(record, cap_digest, now)

          channel = @transport.channel_for(id, viewer_digest)
          context[:subscription_id] = id
          context.namespace(:armory)[:subscription_channel] = channel
          (context.namespace(:__query_result_extensions__)["subscription"] = { "channel" => channel }) if channel
          record_signal(:subscription_created, context: context, engine: record.engine, events: record.events.size)
          nil
        rescue RefusedError => error
          refuse(query, error.reason)
        rescue ArgumentError
          # A value the record cannot hold (an empty operation name or profile): refused, never stored half-made.
          refuse(query, :invalid)
        end

        private

        def store_record(record, cap_digest, now)
          answer = begin
            sealed = @encoder.seal(JSON.generate(record.to_h), aad: record.id, purpose: SEAL_PURPOSE)
            @store.write(record.id, sealed, topics: record.topics, viewer: cap_digest, expires_at: record.expires_at,
                                            viewer_cap: @settings.max_per_viewer, topic_cap: @settings.max_per_topic, now: now)
          rescue StandardError
            raise RefusedError.new("the store failed", reason: :store)
          end
          return if answer == :ok

          raise RefusedError.new("the store refused it", reason: Store::ANSWERS.include?(answer) ? answer : :store)
        end

        def refuse(query, reason)
          message, code = REFUSALS.fetch(reason, REFUSED)
          query.context.errors << GraphQL::ExecutionError.new(message, extensions: { "code" => code })
          record_signal(:subscription_refused, context: query.context, reason: reason)
          nil
        end

        # The text a delivery runs: the request's, or the persisted operation's document printed (what PersistedQueries
        # compares a re-sent text with).
        def document_of(query)
          text = query.query_string
          return text if text.is_a?(String) && !text.empty?

          query.document.to_query_string
        end

        def dump_variables(query)
          variables = query.provided_variables
          variables = variables.to_unsafe_h if variables.respond_to?(:to_unsafe_h)
          serialize(variables || {})
        rescue StandardError
          raise RefusedError.new("the variables cannot be stored", reason: :variables)
        end

        # graphql-ruby's own encoding, so its `load` reads it back. graphql before 2.5 passes `quirks_mode:` to
        # `JSON.generate`, which json 3 refuses as an unknown keyword: the same value is then generated
        # without it.
        def serialize(value)
          GraphQL::Subscriptions::Serialize.dump(value)
        rescue ArgumentError
          JSON.generate(GraphQL::Subscriptions::Serialize.send(:dump_value, value))
        end

        # Only when PersistedQueries ran the stored operation: its mark lives where a client cannot write.
        def persisted_id(context)
          return nil unless Caching::RecordKeys.persisted?(context)

          operation_id = context[:operation_id]
          operation_id.is_a?(String) && !operation_id.empty? ? operation_id : nil
        end

        # The label Versioning decided for the request, not the raw `armory_version`.
        def version_label(context)
          return nil unless context.namespace?(:armory)

          version = context.namespace(:armory)[:version]
          version.respond_to?(:label) && version.label.is_a?(String) ? version.label : nil
        end

        def visibility_profile(context)
          profile = context[:visibility_profile]
          profile.nil? ? nil : profile.to_s
        end

        # Each configured key the context holds, dumped, then loaded back and compared: `dump_value` passes unknown
        # objects through, which would come back as something else.
        def stored_context(context)
          @settings.context_keys.each_key.with_object({}) do |key, stored|
            next unless context.key?(key)

            value = context[key]
            dumped = serialize(value)
            raise RefusedError.new("a context key does not round-trip", reason: :context) unless GraphQL::Subscriptions::Serialize.load(dumped) == value

            stored[key.to_s] = dumped
          rescue RefusedError
            raise
          rescue StandardError
            raise RefusedError.new("a context key cannot be stored", reason: :context)
          end
        end

        # graphql-ruby's topic and the core's digest for each event.
        def digested(query, events)
          events.map do |event|
            field = query.types.field(@schema.subscription, event.name) || raise(RefusedError.new("unknown subscription field", reason: :topic))
            scope_key = field.subscription_scope
            scope = scope_key ? query.context[scope_key] : nil
            digest = begin
              Topic.digest(@encoder, field, event.arguments, scope, context: query.context)
            rescue ArgumentError
              raise RefusedError.new("the arguments or scope do not make a topic", reason: :topic)
            end
            { graphql_topic: event.topic, digest: digest }
          end
        end
      end
    end
  end
end
