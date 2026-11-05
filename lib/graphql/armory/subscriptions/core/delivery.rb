# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Core < GraphQL::Subscriptions
        # What replaces a result over the transport's limit: the core never truncates one, the client refetches.
        TOO_LARGE = { "errors" => [{ "message" => "Result too large", "extensions" => { "code" => "RESULT_TOO_LARGE" } }] }.freeze

        # One message ready for the transport, with what to do once it was sent: `ending` (a reason) deletes the
        # subscription, `delivered` (telemetry data) records a result that reached the provider.
        Delivery = Struct.new(:id, :message, :ending, :context, :delivered, keyword_init: true)

        # Runs the live subscribers of the event's topic (at most `max_executions_per_trigger`), each as itself, and
        # publishes their messages in batches. An error with one subscriber is recorded and the others go on;
        # `on_delivery_error: :raise` raises the first one after the whole topic was processed.
        def execute_all(event, object)
          raise ArgumentError, "execute_all takes the event trigger built (it carries the core's topic digest)" unless event.is_a?(Event)

          now = now_ms
          errors = []
          ids = begin
            @store.ids(event.digest, now: now)
          rescue StandardError => error
            record_signal(:subscription_delivery_error, error: error.class.name)
            errors << error
            []
          end
          ids = within_budget(ids)
          deliveries = ids.filter_map do |id|
            run(id, event.digest, object, now)
          rescue StandardError => error
            record_signal(:subscription_delivery_error, error: error.class.name, subscription: id_digest(id))
            errors << error
            nil
          end
          publish(deliveries, errors)
          raise errors.first if !errors.empty? && @settings.on_delivery_error == :raise

          nil
        end

        # One subscriber of `event`, through the same path as `execute_all`.
        def execute(subscription_id, event, object)
          raise ArgumentError, "execute takes the event trigger built (it carries the core's topic digest)" unless event.is_a?(Event)

          errors = []
          delivery = run(subscription_id, event.digest, object, now_ms)
          publish([delivery].compact, errors)
          raise errors.first if !errors.empty? && @settings.on_delivery_error == :raise

          nil
        end

        # Never used: graphql-ruby's execute_update merges the trigger's context over the subscriber's. Every delivery
        # goes through `trigger`.
        def execute_update(_subscription_id, _event, _object)
          raise NotImplementedError, "#{self.class.name} runs every delivery through trigger: execute_update is not used"
        end

        # Never used: a result is sent only by the delivery that computed it as its subscriber.
        def deliver(_subscription_id, _result)
          raise NotImplementedError, "#{self.class.name} runs every delivery through trigger: deliver is not used"
        end

        private

        def within_budget(ids)
          budget = @settings.max_executions_per_trigger
          return ids if ids.size <= budget

          record_signal(:subscription_trigger_budget, skipped: ids.size - budget)
          ids.first(budget)
        end

        # The Delivery for one subscriber, or nil when nothing is sent.
        def run(id, digest, object, now)
          sealed = @store.read(id)
          if sealed.nil?
            @store.delete(id)
            return nil
          end
          record = open_record(id, sealed)
          return nil unless record
          return Delivery.new(id: id, message: message_for(record, { more: false }), ending: :expired) if record.expired?(now)

          unless record.topics.include?(digest)
            # The index and the record drifted: never run it for a topic it was not written under.
            @store.delete(id)
            record_signal(:subscription_ended, reason: :drift, subscription: id_digest(id))
            return nil
          end

          values = begin
            fresh_context(record)
          rescue ViewerGone
            return Delivery.new(id: id, message: message_for(record, { more: false }), ending: :viewer_gone)
          end
          query = delivery_query(record, digest, values, object)
          result = record.engine == :next ? @schema.multiplex_next([query]).first : @schema.multiplex([query]).first
          conclude(record, query, result)
        end

        # The record `sealed` holds, or nil after deleting it: a record that does not open (another key, moved under
        # another id, tampered) or does not parse is never loaded.
        def open_record(id, sealed)
          text = @encoder.open(sealed, aad: id, purpose: SEAL_PURPOSE).dup.force_encoding(Encoding::UTF_8)
          record = Record.from_h(JSON.parse(text))
          raise ArgumentError, "the record holds another id" unless record.id == id

          record
        rescue StandardError
          @store.delete(id)
          record_signal(:subscription_record_unreadable, subscription: id_digest(id))
          nil
        end

        # A fresh context Hash: the stored `context_keys:` values, the decided version, the persisted operation and the
        # raw-query flag as stored, then the reloaded viewer. Nothing from the trigger.
        def fresh_context(record)
          keys = @settings.context_keys.keys.to_h { |key| [key.to_s, key] }
          values = record.context.each_with_object({}) do |(key, dumped), loaded|
            name = keys[key]
            loaded[name] = GraphQL::Subscriptions::Serialize.load(dumped) if name
          end
          values[:armory_version] = record.version if record.version
          values[:operation_id] = record.operation_id if record.operation_id
          values[:armory_allow_raw_query] = true if record.raw_query
          @settings.viewer.load(record.viewer_id, values) unless record.anonymous?
          values
        end

        # Built through the schema's query class, so Versioning, PersistedQueries and Authorization decide it like a
        # request; then marked as a delivery (a namespace exists only after `Query.new`, and no request can write it).
        def delivery_query(record, digest, values, object)
          options = { variables: GraphQL::Subscriptions::Serialize.load(record.variables), operation_name: record.operation_name, context: values,
                      subscription_topic: record.graphql_topic(digest), root_value: object, validate: true }
          options[:visibility_profile] = record.visibility_profile.to_sym if record.visibility_profile
          query = @schema.query_class.new(@schema, record.document, **options)
          Subscriptions.delivery!(query.context, record.id)
          query
        end

        # graphql-ruby's own flags first (`unsubscribe`, `:no_update`), then the ending rule: no `data`, or a null root
        # field, ends the subscription with a final message. A nested null does not.
        def conclude(record, query, result)
          flags = query.context.namespace(:subscriptions)
          hash = result.to_h
          if flags[:unsubscribed]
            payload = flags[:final_update] ? { result: hash, more: false } : { more: false }
            return delivery_for(record, query, payload, :unsubscribed)
          end
          return nil if flags[:no_update]

          ending = refused?(hash) ? :refused : nil
          delivery_for(record, query, { result: hash, more: ending.nil? }, ending)
        end

        def refused?(hash)
          data = hash["data"]
          !data.is_a?(Hash) || data.empty? || data.each_value.any?(&:nil?)
        end

        def delivery_for(record, query, payload, ending)
          message = message_for(record, payload, context: query.context)
          delivered = nil
          if message&.payload&.key?(:result) || message&.payload&.key?(:compressed_result)
            delivered = { subscription: id_digest(record.id), complexity: complexity_of(query), bytes: JSON.generate(message.payload).bytesize }
          end
          Delivery.new(id: record.id, message: message, ending: ending, context: query.context, delivered: delivered)
        end

        # The transport's message for `payload`: compressed when the transport says the client inflates, replaced with
        # RESULT_TOO_LARGE over its limit. Nil when even that does not fit (recorded): nothing is sent.
        def message_for(record, payload, context: nil)
          channel = @transport.channel_for(record.id, record.viewer_digest)
          capabilities = @transport.capabilities
          payload = compressed(payload) if payload.key?(:result) && capabilities.compress?
          bytes = JSON.generate(payload).bytesize
          if bytes > capabilities.max_payload_bytes
            record_signal(:subscription_payload_too_large, context: context, subscription: id_digest(record.id), bytes: bytes, limit: capabilities.max_payload_bytes)
            payload = { result: TOO_LARGE, more: payload[:more] }
            return nil if JSON.generate(payload).bytesize > capabilities.max_payload_bytes
          end
          Message.new(channel: channel, payload: payload)
        end

        def compressed(payload)
          { compressed_result: Base64.strict_encode64(Zlib::Deflate.deflate(JSON.generate(payload[:result]))), more: payload[:more] }
        end

        # The delivery's complexity for telemetry, when someone listens: graphql-ruby's own QueryComplexity analyzer.
        def complexity_of(query)
          return nil unless @telemetry.listening? && query.valid?

          complexity = GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::QueryComplexity]).first
          complexity.is_a?(Integer) ? complexity : nil
        rescue StandardError
          nil
        end

        # Sends in batches of the transport's max_batch, then deletes what ended (whether or not it was sent) and what
        # the transport reports gone.
        def publish(deliveries, errors)
          deliveries.each_slice(@transport.capabilities.max_batch) do |batch|
            sendable = batch.reject { |delivery| delivery.message.nil? }
            outcomes = send_batch(sendable, errors)
            sendable.each_with_index do |delivery, index|
              settle(delivery, outcomes&.find { |outcome| outcome.is_a?(Outcome) && outcome.index == index })
            end
            batch.each { |delivery| finish(delivery) if delivery.ending }
          end
        end

        def send_batch(sendable, errors)
          return [] if sendable.empty?

          outcomes = @transport.publish(sendable.map(&:message))
          raise TransportError, "publish answered #{outcomes.class}, not an Array of Outcomes" unless outcomes.is_a?(Array)

          outcomes
        rescue StandardError => error
          record_signal(:subscription_transport_error, operation: :publish, error: error.class.name)
          errors << error
          nil
        end

        def settle(delivery, outcome)
          return unless outcome

          case outcome.status
          when :ok
            record_signal(:subscription_delivered, context: delivery.context, **delivery.delivered) if delivery.delivered
          when :gone
            delivery.ending = nil
            finish(delivery, :gone)
          when :refused
            record_signal(:subscription_transport_error, context: delivery.context, operation: :publish, outcome: :refused, reason: outcome.reason)
          end
        end

        def finish(delivery, reason = delivery.ending)
          @store.delete(delivery.id)
          record_signal(:subscription_ended, context: delivery.context, reason: reason, subscription: id_digest(delivery.id))
        end
      end
    end
  end
end
