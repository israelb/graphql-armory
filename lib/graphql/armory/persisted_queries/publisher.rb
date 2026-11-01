# frozen_string_literal: true

require "optparse"

module GraphQL
  module Armory
    module PersistedQueries
      # Publishes a client build's manifest to Redis, for `RedisStore` to read. It only adds: an id that already holds
      # another query raises and stays as it was. Publishing again is safe, so a failed run can simply run again.
      #
      #   GraphQL::Armory::PersistedQueries::Publisher.call(Manifest.load("manifest.json"), redis: Redis.new(url: url))
      class Publisher
        # An id it could not store, or that holds another query. The message quotes neither query.
        class PublishError < Armory::Error; end

        Result = Struct.new(:published, :unchanged, keyword_init: true)

        def self.build(redis:, prefix: RedisStore::DEFAULT_PREFIX)
          raise ConfigurationError, "redis: must answer get and set, like Redis.new from the redis gem" unless redis.respond_to?(:get) && redis.respond_to?(:set)
          raise ConfigurationError, "prefix: must be a non-empty String, got #{prefix.inspect}" unless prefix.is_a?(String) && !prefix.empty?

          new(redis: redis, prefix: prefix)
        end

        def self.call(manifest, **options)
          build(**options).(manifest)
        end

        # `new` is inert: with no Redis wired, nothing is stored and `call` raises.
        def initialize(redis: RedisStore::Client::Null.new, prefix: RedisStore::DEFAULT_PREFIX)
          @redis = redis
          @prefix = prefix
        end

        def call(manifest)
          raise ConfigurationError, "publish a Manifest: Manifest.load checks every id and query" unless manifest.instance_of?(Manifest)

          check_ids(manifest)
          published = manifest.operations.count { |id, operation| publish(id, operation.body) }
          Result.new(published: published, unchanged: manifest.size - published)
        end

        private

        # Before anything is stored: `RedisStore` never asks for an id of another shape.
        def check_ids(manifest)
          manifest.operations.keys.each_with_index do |id, index|
            raise ConfigurationError, "the operation at entry #{index} has an id RedisStore cannot read" unless id.match?(Manifest::ID_LIKE)
          end
        end

        # Answers whether it was new. SET NX, so two runs at once cannot overwrite each other.
        def publish(id, body)
          key = "#{@prefix}#{id}"
          return true if @redis.set(key, body, nx: true)

          stored = @redis.get(key)
          raise PublishError, "operation #{id} was not stored" if stored.nil?
          raise PublishError, "operation #{id} already holds another query: published operations never change" unless stored.b == body.b

          false
        end

        # The `graphql-armory-publish` executable, for a client's CI. Answers the exit code. Redis's messages may hold
        # the URL and its password, so only the error's class is printed.
        class Command
          USAGE = "Usage: graphql-armory-publish [--digest sha256|sha1|md5|false] [--prefix PREFIX] MANIFEST...\nReads REDIS_URL."

          def self.call(argv = ARGV, env: ENV, out: $stdout, err: $stderr, client: nil)
            new(env: env, out: out, err: err, client: client).(argv)
          end

          def initialize(env: {}, out: $stdout, err: $stderr, client: nil)
            @env = env
            @out = out
            @err = err
            @client = client
          end

          def call(argv)
            digest, prefix, paths = options(argv)
            return fail_with(USAGE) if paths.empty?

            url = @env["REDIS_URL"]
            return fail_with("REDIS_URL is not set") if url.to_s.empty?

            manifests = paths.map { |path| [path, Manifest.load(path, digest: digest)] }
            publisher = Publisher.build(redis: @client || redis(url), prefix: prefix)
            manifests.each do |path, manifest|
              result = publisher.(manifest)
              @out.puts "#{path}: #{result.published} published, #{result.unchanged} unchanged"
            end
            0
          rescue OptionParser::ParseError, Armory::Error => error
            fail_with(error.message)
          rescue LoadError
            fail_with("graphql-armory-publish needs the redis gem: gem install redis")
          rescue StandardError => error
            fail_with("publishing failed (#{error.class})")
          end

          private

          def options(argv)
            digest = :sha256
            prefix = RedisStore::DEFAULT_PREFIX
            paths = OptionParser.new do |parser|
              parser.on("--digest NAME") { |name| digest = name == "false" ? false : name.to_sym }
              parser.on("--prefix PREFIX") { |given| prefix = given }
            end.parse(argv)
            [digest, prefix, paths]
          end

          def redis(url)
            require "redis"
            Redis.new(url: url)
          end

          def fail_with(message)
            @err.puts message
            1
          end
        end
      end
    end
  end
end
