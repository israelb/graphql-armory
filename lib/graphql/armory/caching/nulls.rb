# frozen_string_literal: true

module GraphQL
  module Armory
    module Caching
      # Answers what it is told (`answer(value)`) to every call and records the arguments in `calls`.
      module Answering
        attr_reader :calls

        def initialize(answer)
          @answer = answer
          @calls = []
        end

        def answer(value)
          @answer = value
        end

        def call(*arguments)
          @calls << arguments
          @answer
        end
      end

      # The operation's policy from its declarations: `walk.(query) -> Policy`. `Null` refuses everything.
      class Walk
        class Null
          def call(_query) = Policy.refused(:unconfigured)
        end

        class Substitute
          include Answering

          def initialize(policy = Policy.refused(:unconfigured)) = super
        end
      end

      # The request's Key: `keyer.(query, policy) -> Key | Policy.refused(reason)`. `Null` refuses everything.
      class Keyer
        class Null
          def call(_query, _policy, **) = Policy.refused(:unconfigured)
        end

        class Substitute
          include Answering

          def initialize(key = Policy.refused(:unconfigured)) = super
        end
      end

      # Serializes and seals entries: `codec.encode(entry, key_digest) -> String`,
      # `codec.decode(string, key_digest) -> Entry`, raising `Entry::Rejected` with its reason.
      class Codec
        # Plain JSON with the key check, rejecting with the reason it is told (`reject_with(:decrypt)`); records `calls`.
        class Substitute
          attr_reader :calls

          def initialize
            @calls = []
            @rejection = nil
          end

          def reject_with(reason)
            @rejection = reason
          end

          def recover
            @rejection = nil
          end

          def encode(entry, key_digest)
            @calls << [:encode, key_digest]
            entry.to_json_string
          end

          def decode(string, key_digest)
            @calls << [:decode, key_digest]
            raise Entry::Rejected, @rejection if @rejection

            entry = Entry.parse(string)
            raise Entry::Rejected, :key unless entry.key == key_digest

            entry
          end
        end
      end

      # Charges a hit the Points its run cost: `charge.(query, cost)` answers nil (charged) or the
      # limiter's refusal.
      class Charge
        # Charges nothing: for schemas without a Points limiter.
        class Null
          def call(_query, _cost) = nil
        end

        # Answers what it is told (`refuse_with(refusal)`, `recover`) and records `calls` as `[query, cost]`.
        class Substitute
          attr_reader :calls

          def initialize
            @calls = []
            @refusal = nil
          end

          def refuse_with(refusal)
            @refusal = refusal
          end

          def recover
            @refusal = nil
          end

          def call(query, cost)
            @calls << [query, cost]
            @refusal
          end
        end
      end
    end
  end
end
