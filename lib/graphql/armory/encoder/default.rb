# frozen_string_literal: true

module GraphQL
  module Armory
    class Encoder
      ENV_KEY = "GRAPHQL_ARMORY_KEY"
      RAILS_PURPOSE = "graphql-armory/ids"

      # An encoder whose key comes from the app, never from the gem: `GRAPHQL_ARMORY_KEY`, or else a key derived
      # with HKDF from Rails' secret_key_base for this purpose alone. Without either it raises, so the app fails
      # when the schema loads instead of serving unencrypted IDs.
      #
      # It reads `secret_key_base` instead of `Rails.application.key_generator`: that generator is built once per
      # process with whatever digest Rails has configured at that moment, which changes during boot, so the same
      # secret could give different IDs in a web server and in a rake task (and calling it early would also fix
      # Rails' own cookie keys to the wrong digest).
      def self.default(env: ENV, rails: rails_application)
        secret = env_key(env)
        secret = rails_key(rails) if secret.nil? && rails
        if secret.nil?
          raise ConfigurationError,
                "no key for the default encoder: set #{ENV_KEY} (try `ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`), " \
                "or run inside a Rails app with a secret_key_base"
        end

        Class.new(self) { key(secret) }
      end

      def self.env_key(env)
        value = env[ENV_KEY].to_s
        return nil if value.empty?
        if value.strip != value || value.strip.empty?
          raise ConfigurationError, "#{ENV_KEY} has leading or trailing whitespace, or only whitespace: remove it"
        end

        value
      end
      private_class_method :env_key

      def self.rails_application
        ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application)
      end
      private_class_method :rails_application

      def self.rails_key(rails)
        secret = begin
          rails.secret_key_base
        rescue StandardError => error
          # Rails' message may come from app code; name only its class so nothing secret is echoed.
          raise ConfigurationError, "the default encoder could not read Rails' secret_key_base (#{error.class})"
        end
        raise ConfigurationError, "this Rails app has no secret_key_base for the default encoder" if secret.to_s.empty?

        OpenSSL::KDF.hkdf(secret.to_s, salt: "graphql-armory", info: RAILS_PURPOSE, length: 32, hash: "SHA256")
      end
      private_class_method :rails_key
    end
  end
end
