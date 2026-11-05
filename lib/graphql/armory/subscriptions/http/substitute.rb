# frozen_string_literal: true

module GraphQL
  module Armory
    module Subscriptions
      class Http
        # An HTTP client that records each request (`requests`: `{ url:, body:, headers: }`), answers the response it is
        # told (200 with `{}` by default) and fails when told: for transport tests, instead of hand-written fakes.
        class Substitute
          attr_reader :requests

          def initialize
            @requests = []
            @response = Response.new(status: 200, body: "{}", headers: {})
            @failure = nil
          end

          # Answers this response to every following request.
          def answer(status:, body: "", headers: {})
            @response = Response.new(status: status, body: body, headers: headers)
          end

          # Raises `error` from the next `times` requests, or every request until `recover`.
          def fail_with(error, times: nil)
            raise ArgumentError, "times: must be nil (every call) or a positive Integer, got #{times.inspect}" unless times.nil? || (times.is_a?(Integer) && times.positive?)

            @failure = [error, times]
          end

          def recover
            @failure = nil
          end

          def post(url, body, headers = {})
            @requests << { url: url, body: body, headers: headers }
            fail!
            @response
          end

          private

          def fail!
            return unless @failure

            error, times = @failure
            if times
              times -= 1
              @failure = times.zero? ? nil : [error, times]
            end
            raise error
          end
        end
      end
    end
  end
end
