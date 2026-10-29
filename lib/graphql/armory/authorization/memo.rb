# frozen_string_literal: true

module GraphQL
  module Armory
    module Authorization
      # Remembers answers for the length of a request, so the same question is not asked twice.
      class Memo
        def self.build(context)
          store = context.namespace(:armory)
          store[:memo] ||= new
        end

        def initialize
          # Keyed by identity: two equal-looking records are different subjects, and holding the
          # subject as a key keeps it alive, so an object id can never be recycled for another one.
          @answers = {}.compare_by_identity
        end

        def fetch(subject, rule)
          answers = (@answers[subject] ||= {})
          return answers[rule] if answers.key?(rule)

          answers[rule] = yield
        end

        # Never remembers: every question runs.
        class Substitute
          def fetch(_subject, _rule)
            yield
          end
        end
      end
    end
  end
end
