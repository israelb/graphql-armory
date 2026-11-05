# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Subscriptions
      module Transport
        # A transport that records what it published, answers the outcomes it is told, declares whatever capabilities
        # and authorization mode it is given, and fails when told: for tests, instead of hand-written fakes. It keeps
        # the transport contract it can check: a batch over `max_batch` or a payload over `max_payload_bytes` raises
        # ArgumentError (a bug in the caller), and channels are `<prefix>:<viewer digest>:<id>`.
        #
        #   transport = Transport::Substitute.new(authorization: :viewer)
        #   transport.answer_publish(:gone, channel: channel)
        #   transport.answer(:webhook, [:ok, [channel]])
        #   transport.published              # => [Message, ...]
        class Substitute
          OPERATIONS = %i[publish authorize_channel authorize_viewer webhook].freeze
          ANSWERABLE = %i[authorize_channel authorize_viewer webhook].freeze
          SEGMENT = /\A[A-Za-z0-9_-]+\z/
          DEFAULT_CAPABILITIES = Capabilities.new(viewer_bound: true, max_payload_bytes: 10_240, max_batch: 10, webhooks: :existence, compress: false)

          attr_reader :capabilities, :authorization, :published, :batches, :calls

          def initialize(capabilities: DEFAULT_CAPABILITIES, authorization: :channel, prefix: "substitute")
            raise ArgumentError, "capabilities: must be a Capabilities, got #{capabilities.class}" unless capabilities.is_a?(Capabilities)
            raise ArgumentError, "authorization: must be one of #{AUTHORIZATIONS.inspect}, got #{authorization.inspect}" unless AUTHORIZATIONS.include?(authorization)
            raise ArgumentError, "prefix: must be letters, digits, _ or -" unless prefix.is_a?(String) && SEGMENT.match?(prefix)

            @capabilities = capabilities
            @authorization = authorization
            @prefix = prefix
            @published = []
            @batches = []
            @calls = []
            @statuses = {}
            @default_status = [:ok, nil]
            @answers = {}
            @failures = {}
          end

          # Answers `status` (with `reason`) for every message to `channel`, or to every channel without one of its own.
          def answer_publish(status, channel: nil, reason: nil)
            raise ArgumentError, "status must be one of #{Outcome::STATUSES.inspect}, got #{status.inspect}" unless Outcome::STATUSES.include?(status)

            channel ? @statuses[channel] = [status, reason] : @default_status = [status, reason]
          end

          # Answers `value` from `operation` (an authorization or a webhook) instead of the real answer.
          def answer(operation, value)
            raise ArgumentError, "operation must be one of #{ANSWERABLE.inspect} (publish: answer_publish)" unless ANSWERABLE.include?(operation)

            @answers[operation] = value
          end

          # Raises `error` from `on` (an operation, or :all) for the next `times` calls, or every call until `recover`.
          def fail_with(error, on: :all, times: nil)
            raise ArgumentError, "on: must be one of #{(OPERATIONS + [:all]).inspect}, got #{on.inspect}" unless (OPERATIONS + [:all]).include?(on)
            raise ArgumentError, "times: must be nil (every call) or a positive Integer, got #{times.inspect}" unless times.nil? || (times.is_a?(Integer) && times.positive?)

            @failures[on] = [error, times]
          end

          def recover
            @failures.clear
          end

          # The messages published to `channel`, in order.
          def delivered_to(channel)
            published.select { |message| message.channel == channel }
          end

          def channel_for(id, viewer_digest)
            [@prefix, viewer_digest, id].join(":")
          end

          def id_from(channel)
            return nil unless channel.is_a?(String)

            prefix, digest, id, *rest = channel.split(":", -1)
            return nil unless prefix == @prefix && rest.empty? && [digest, id].all? { |part| part && SEGMENT.match?(part) }

            id
          end

          def publish(messages)
            check(messages)
            perform(:publish, size: messages.size) do
              @batches << messages.dup.freeze
              @published.concat(messages)
              messages.each_with_index.map do |message, index|
                status, reason = @statuses.fetch(message.channel, @default_status)
                Outcome.new(status: status, index: index, reason: reason)
              end
            end
          end

          def authorize_channel(channel:, socket_id: nil)
            perform(:authorize_channel, channel: channel, socket_id: socket_id) do
              authorization == :channel ? { auth: "substitute:#{socket_id}:#{channel}" } : nil
            end
          end

          def authorize_viewer(viewer_digest)
            perform(:authorize_viewer, viewer_digest: viewer_digest) do
              authorization == :viewer ? { token: "substitute:#{viewer_digest}" } : nil
            end
          end

          def webhook(env)
            perform(:webhook, env: env) { [:ok, []] }
          end

          private

          def check(messages)
            raise ArgumentError, "publish takes a non-empty Array of Messages" unless messages.is_a?(Array) && !messages.empty? && messages.all?(Message)
            raise ArgumentError, "publish got #{messages.size} messages, over max_batch #{capabilities.max_batch}" if messages.size > capabilities.max_batch

            messages.each do |message|
              bytes = JSON.generate(message.payload).bytesize
              raise ArgumentError, "a payload of #{bytes} bytes is over max_payload_bytes #{capabilities.max_payload_bytes}" if bytes > capabilities.max_payload_bytes
            end
          end

          def perform(operation, **arguments)
            @calls << [operation, arguments]
            fail!(operation)
            return @answers[operation] if @answers.key?(operation)

            yield
          end

          def fail!(operation)
            on = @failures.key?(operation) ? operation : :all
            error, times = @failures[on]
            return unless error

            if times
              times -= 1
              times.zero? ? @failures.delete(on) : @failures[on] = [error, times]
            end
            raise error
          end
        end
      end
    end
  end
end
