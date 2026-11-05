# frozen_string_literal: true

require "graphql/armory/caching/recorder/log"

module GraphQL
  module Armory
    module Caching
      module Recorder
        # The context class `use` wraps around the schema's own: it records every read and write from construction on
        # (docs/response-caching.md "Inputs you must declare"), into a `Log` stored with `RecordKeys.recorder!`.
        #
        # `Recorder::Context.wrap(klass) -> Class` answers a subclass of `klass` that records, the same class for the
        # same `klass` every time (thread-safe), and `klass` itself when it is already a wrapper. A subclass of a wrapper
        # is wrapped again, so its own overrides are recorded too; both levels then share one Log.
        #
        # What it records, every override calling `super`:
        #
        # - reads: `[]`, `fetch`, `dig` (its first key), `key?`, present or absent. A read the query's own scoped
        #   context answers (a value this query set with `scoped_set!` above the reading field) is not recorded;
        # - the whole context (`Recorder::ALL`): `to_h`, `to_hash`, `namespace(nil)` and `scoped_context` (graphql-ruby's
        #   own use of that reader inside `Query::Context` is not the app's and is not recorded);
        # - writes: `[]=`, `delete`, `scoped_merge!`, `scoped_set!`, and `set!`/`merge!` on the object `scoped` answers.
        #
        # `dataloader`: once `query.multiplex` is bound it answers `super` (the multiplex's dataloader). Before that it
        # answers `context[:dataloader]` or a fresh dataloader each time, never memoized, so a pre-run caller (an app
        # `visible?` during the walk) leaves no stray dataloader on the query. Its read of `:dataloader` is not recorded
        # in either case: it is graphql-ruby choosing its executor, a key the gate covers anyway.
        module Context
          WRAPPERS = {}.compare_by_identity # wrapped class => wrapper
          WRAPPED = {}.compare_by_identity  # wrapper => wrapped class
          LOCK = Mutex.new

          BASE = GraphQL::Query::Context
          BASE_NAMESPACE = BASE.instance_method(:namespace)
          BASE_SCOPED_CONTEXT = BASE.instance_method(:scoped_context)
          # Calls of `scoped_context` from these files are graphql-ruby's own (`fetch`) or a wrapper's `super`.
          INTERNAL_FILES = [BASE.instance_method(:fetch).source_location&.first, __FILE__].compact.freeze

          def self.wrap(klass)
            raise ArgumentError, "expected a GraphQL::Query::Context subclass, got #{klass.inspect}" unless klass.is_a?(Class) && klass <= BASE
            return klass if WRAPPED.key?(klass)

            WRAPPERS[klass] || LOCK.synchronize do
              WRAPPERS[klass] ||= Class.new(klass) do
                include Wrapped
                class_exec(&RECORDING)
              end.tap { |wrapper| WRAPPED[wrapper] = klass }
            end
          end

          # A class `wrap` built.
          def self.wrapper?(klass)
            WRAPPED.key?(klass)
          end

          # Marks a wrapper class (and its subclasses).
          module Wrapped
          end

          # The writer `context.scoped` answers, recording the keys it sets.
          class ScopedWrites
            def initialize(scoped, log)
              @scoped = scoped
              @log = log
            end

            def merge!(hash)
              hash.each_key { |key| @log.write_scoped(key) }
              @scoped.merge!(hash)
            end

            def set!(key, value)
              @log.write_scoped(key)
              @scoped.set!(key, value)
            end
          end

          # The overrides, defined on each wrapper itself (not included from a module) so that a wrapper of a subclass of
          # a wrapper still sits first in the ancestry: Ruby does not include a module twice in one chain.
          RECORDING = proc do
            def initialize(...)
              armory_log
              super(...)
              @armory_log.share(BASE_NAMESPACE.bind_call(self, nil))
              RecordKeys.recorder!(self, @armory_log)
            end

            def [](key)
              armory_read(key)
              super
            end

            def fetch(key, *rest, &block)
              armory_read(key)
              super
            end

            def dig(key, *rest)
              armory_read(key)
              super
            end

            def key?(key)
              armory_read(key)
              super
            end

            def to_h
              armory_log.read_all
              super
            end

            def to_hash
              armory_log.read_all
              super
            end

            def namespace(ns)
              armory_log.read_all if ns.nil?
              super
            end

            def scoped_context
              armory_log.read_all unless INTERNAL_FILES.include?(caller_locations(1, 1).first&.path)
              super
            end

            def []=(key, value)
              armory_log.write(key)
              super
            end

            def delete(key)
              armory_scoped_key?(key) ? armory_log.write_scoped(key) : armory_log.write(key)
              super
            end

            def scoped_merge!(hash)
              hash.each_key { |key| armory_log.write_scoped(key) }
              super
            end

            def scoped_set!(key, value)
              armory_log.write_scoped(key)
              super
            end

            def scoped
              ScopedWrites.new(super, armory_log)
            end

            def dataloader
              return armory_log.neutral { super } if query.multiplex

              armory_log.neutral { self[:dataloader] } || schema.dataloader_class.new
            end

            private

            def armory_log
              @armory_log ||= Log.new
            end

            # A key whose value comes from this query's own scoped context is not an input.
            def armory_read(key)
              log = armory_log
              log.read(key) unless log.scoped_written?(key) && armory_scoped_key?(key)
            end

            def armory_scoped_key?(key)
              BASE_SCOPED_CONTEXT.bind_call(self).key?(key)
            end
          end
        end
      end
    end
  end
end
