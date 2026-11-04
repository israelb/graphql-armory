# frozen_string_literal: true

module GraphQL
  module Armory
    module Versioning
      # Decides, once per request, which version it is served, from `context[:armory_version]`: a served label is served,
      # a retired one is refused, nothing at all follows the `default:` policy, and anything else (an unknown or future
      # label, an empty String, a non-String) is refused. It never falls back to another version.
      class Gate
        # What `default:` holds when `use` was not given one.
        UNSET = Object.new.tap { |unset| def unset.inspect = "(not given)" }.freeze

        # When every label looks like a date, the list must be ascending: its order is the whole meaning.
        DATE = /\A\d{4}-\d{2}-\d{2}\z/

        # Validates `use`'s settings and wires the real list, policy and telemetry; `use` goes through here.
        def self.build(versions:, default: UNSET, retired: [], sinks: [], on_sink_error: nil)
          check_versions(versions)
          check_retired(versions, retired)
          policy = default_policy(default, versions, retired)

          new(versions: Versions.new(versions, retired: retired), default: policy, telemetry: Telemetry.build(sinks: sinks, on_sink_error: on_sink_error))
        end

        def self.check_versions(versions)
          raise ConfigurationError, "versions: must be an Array of labels, oldest first, got #{versions.class}" unless versions.is_a?(Array)
          raise ConfigurationError, "versions: must name at least one version" if versions.empty?

          versions.each do |label|
            raise ConfigurationError, "versions: each label must be a non-empty String, got #{label.inspect}" unless label.is_a?(String) && !label.empty?
          end
          duplicate = versions.find { |label| versions.count(label) > 1 }
          raise ConfigurationError, "versions: #{duplicate.inspect} is listed twice" if duplicate
          raise ConfigurationError, "versions: dates must be in ascending order, oldest first" if versions.all?(DATE) && versions != versions.sort
        end
        private_class_method :check_versions

        def self.check_retired(versions, retired)
          raise ConfigurationError, "retired: must be an Array of labels, got #{retired.class}" unless retired.is_a?(Array)
          raise ConfigurationError, "retired: must be the oldest versions, a prefix of versions:, got #{retired.inspect}" unless versions.first(retired.size) == retired
          raise ConfigurationError, "retired: leaves no version to serve" if retired.size == versions.size
        end
        private_class_method :check_retired

        def self.default_policy(default, versions, retired)
          case default
          when :latest then Default::Latest.new
          when :refuse then Default::Refuse.new
          when String
            raise ConfigurationError, "default: #{default.inspect} is retired: pick a served version" if retired.include?(default)
            raise ConfigurationError, "default: #{default.inspect} is not in versions:" unless versions.include?(default)

            Default::Label.new(default)
          when UNSET
            raise ConfigurationError, "default: is required: :latest (a new API), the label your clients see today (an API with clients in production), or :refuse"
          else
            raise ConfigurationError, "default: must be :latest, :refuse or a served label, got #{default.inspect}"
          end
        end
        private_class_method :default_policy

        # `new` is inert: it knows no version and refuses every request.
        def initialize(versions: Versions::Null.new, default: Default::Refuse.new, telemetry: Telemetry.new)
          @versions = versions
          @default = default
          @telemetry = telemetry
        end

        attr_reader :versions

        # The decision for a request, recorded as one signal. `Lookup` calls it once per query.
        def call(context)
          decision = resolve(context.respond_to?(:[]) ? context[:armory_version] : nil)
          @telemetry.record(decision.signal, context: context.respond_to?(:[]) ? context : {}, **decision.data)
          decision
        end

        # The same decision for a label, recording nothing: for contexts that did not come through `query_class`.
        def resolve(label)
          case label
          when nil then @default.(@versions)
          when String
            return Decision.refused(:retired, version: @versions.fetch(label)) if @versions.retired?(label)
            return Decision.served(@versions.fetch(label)) if @versions.served?(label)

            Decision.refused(:unknown)
          else Decision.refused(:unknown)
          end
        end

        # Answers the decision it is told (a refusal for a missing version until told otherwise) and records the contexts
        # and labels it was asked about: for tests, instead of hand-written gates.
        class Substitute
          attr_reader :contexts, :labels

          def initialize(decision = Decision.refused(:missing))
            @decision = decision
            @contexts = []
            @labels = []
          end

          def answer(decision)
            @decision = decision
          end

          def versions = Versions::Null.new

          def call(context)
            @contexts << context
            @decision
          end

          def resolve(label)
            @labels << label
            @decision
          end
        end
      end
    end
  end
end
