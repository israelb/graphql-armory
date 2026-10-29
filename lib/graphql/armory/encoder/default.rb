# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      ENV_KEY = "GRAPHQL_ARMORY_KEY"
      RAILS_PURPOSE = "graphql-armory/ids"

      # An encoder whose key comes from the app, never from the gem: `GRAPHQL_ARMORY_KEY`, or else a key derived
      # from Rails' secret_key_base for this purpose alone. Without either it raises, so the app fails at boot
      # instead of serving unencrypted IDs.
      def self.default(env: ENV, rails: rails_application)
        secret = env[ENV_KEY].to_s
        secret = rails_key(rails) if secret.empty? && rails
        if secret.nil? || secret.empty?
          raise ConfigurationError,
                "no key for the default encoder: set #{ENV_KEY} (try `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`), " \
                "or run inside a Rails app with a secret_key_base"
        end

        Class.new(self) { key(secret) }
      end

      def self.rails_application
        Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application)
      end
      private_class_method :rails_application

      def self.rails_key(rails)
        rails.key_generator.generate_key(RAILS_PURPOSE, 32)
      rescue StandardError => error
        raise ConfigurationError, "the default encoder could not derive a key from Rails' secret_key_base: #{error.message}"
      end
      private_class_method :rails_key
    end
  end
end
