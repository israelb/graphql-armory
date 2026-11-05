# frozen_string_literal: true

require "json"

module GraphQL
  module Armory
    module Subscriptions
      class Ably
        # Ably's REST batch publish: `POST https://<host>/messages` with an Array of `{channels, messages}` specs, one
        # spec per message (https://ably.com/docs/api/rest-api). A 200 answers `[{channel, messageId}, ...]`; when some
        # inner requests fail it answers 400 with `error.code` 40020 and a `batchResponse` of per-channel results,
        # each `{channel, messageId}` or `{channel, error: {code, statusCode}}`.
        #
        # Every answer becomes an Outcome by message index; nothing a provider says raises. A failure to get an answer
        # (`TransportError`) is `:retry` for the messages of that request only.
        class Publisher
          PARTIAL_FAILURE = 40_020
          TOO_LARGE_CODE = 40_009

          def initialize(key:, url:, http:, max_payload_bytes:, max_batch:)
            @key = key
            @url = url
            @http = http
            @max_payload_bytes = max_payload_bytes
            @max_batch = max_batch
          end

          def call(messages)
            raise ArgumentError, "publish takes an Array of Messages" unless messages.is_a?(Array) && messages.all?(Message)

            outcomes = Array.new(messages.size)
            sendable = []
            messages.each_with_index do |message, index|
              data = encode(message)
              if data.is_a?(Symbol)
                outcomes[index] = Outcome.new(status: :refused, index: index, reason: data)
              else
                sendable << [index, message, data]
              end
            end
            sendable.each_slice(@max_batch) { |chunk| send_chunk(chunk, outcomes) }
            outcomes
          end

          private

          # The JSON text of the payload, or the reason it cannot be sent.
          def encode(message)
            data = JSON.generate(message.payload)
            data.bytesize > @max_payload_bytes ? :too_large : data
          rescue JSON::JSONError, EncodingError
            :unencodable
          end

          def send_chunk(chunk, outcomes)
            verdict = verdict_for(chunk)
            chunk.each do |index, message, _data|
              outcomes[index] =
                if verdict.first == :all
                  Outcome.new(status: verdict[1], index: index, reason: verdict[2])
                else
                  outcome_for(verdict[1][message.channel]&.shift, index)
                end
            end
          end

          # [:all, status, reason] when one answer covers the whole request, or [:each, {channel => [entry, ...]}].
          def verdict_for(chunk)
            response = post(chunk)
            return [:all, :retry, :transport] unless response

            parsed = parse(response.body)
            return success_verdict(parsed) if response.success?

            error = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : {}
            entries = parsed.is_a?(Hash) ? (parsed["batchResponse"] || error["batchResponse"]) : nil
            return [:each, group(entries)] if error["code"] == PARTIAL_FAILURE && entries.is_a?(Array) && entries.all?(Hash)

            [:all, *classify(error["code"], response.status)]
          end

          def success_verdict(parsed)
            return [:all, :retry, :bad_response] unless parsed.is_a?(Array) && parsed.all?(Hash)

            [:each, group(parsed)]
          end

          # The response, or nil when none came.
          def post(chunk)
            specs = chunk.map do |_index, message, data|
              { channels: [message.channel], messages: [{ name: message.event, data: data, encoding: "json" }] }
            end
            @http.post(@url, JSON.generate(specs), "Authorization" => @key.basic_auth, "Content-Type" => "application/json", "Accept" => "application/json")
          rescue TransportError
            nil
          end

          def parse(text)
            JSON.parse(text)
          rescue JSON::ParserError
            nil
          end

          def group(entries)
            entries.each_with_object({}) { |entry, groups| (groups[entry["channel"]] ||= []) << entry }
          end

          def outcome_for(entry, index)
            return Outcome.new(status: :retry, index: index, reason: :missing_result) unless entry
            return Outcome.new(status: :ok, index: index) unless entry["error"]

            error = entry["error"].is_a?(Hash) ? entry["error"] : {}
            status, reason = classify(error["code"], error["statusCode"])
            Outcome.new(status: status, index: index, reason: reason)
          end

          # [status, reason] for an Ably error code (e.g. 40009) and HTTP status.
          def classify(code, status)
            code = code.is_a?(Integer) ? code : 0
            status = status.is_a?(Integer) ? status : 0
            if status == 401 || status == 403 || code.between?(40_100, 40_399) then [:refused, :unauthorized]
            elsif status == 413 || code == TOO_LARGE_CODE then [:refused, :too_large]
            elsif status == 429 || code.between?(42_900, 42_999) then [:retry, :rate_limited]
            elsif status >= 500 || code >= 50_000 then [:retry, :provider_error]
            else [:refused, :bad_request]
            end
          end
        end
      end
    end
  end
end
