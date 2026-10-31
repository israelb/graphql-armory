# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "Adoption fixes" do
  let(:armory) { GraphQL::Armory }
  let(:adapters) { armory::Authorization::Adapters }

  describe "PersistedQueries.operation_id" do
    it "reads Relay's doc_id" do
      expect(armory::PersistedQueries.operation_id("doc_id" => "abc")).to eq("abc")
    end

    it "prefers operationId, and ignores a doc_id that is not a non-empty String" do
      expect(armory::PersistedQueries.operation_id("operationId" => "first", "doc_id" => "second")).to eq("first")
      expect(armory::PersistedQueries.operation_id("doc_id" => "")).to be_nil
      expect(armory::PersistedQueries.operation_id("doc_id" => { "a" => 1 })).to be_nil
    end
  end

  describe "user_key: on the adapters" do
    def invoice_number(adapter, record, **context)
      schema = IntegrationSchema.build(adapter: adapter)
      execute_query(schema, "{ myInvoice { number } }", context: context, root_value: IntegrationSchema::Root.new(my_invoice: record)).dig("data", "myInvoice", "number")
    end

    it "lets Pundit read the user from another context key" do
      adapter = adapters::Pundit.new(user_key: :viewer)

      expect(invoice_number(adapter, world.a1, viewer: world.alice)).to eq(world.a1.number)
      expect(invoice_number(adapter, world.b1, viewer: world.alice)).to be_nil
    end

    it "does not read current_user once another key is named" do
      expect(adapters::Pundit.new(user_key: :viewer).actor({ current_user: :someone })).to be_nil
    end

    it "keeps current_user by default" do
      expect(adapters::Pundit.new.actor({ current_user: :someone })).to eq(:someone)
    end

    it "lets CanCanCan build the Ability from another context key, and current_ability still wins" do
      ability = Class.new do
        attr_reader :user

        def initialize(user) = @user = user
      end
      adapter = adapters::CanCan.new(ability_class: ability, user_key: :viewer)
      context = Class.new(Hash) { def namespace(_name) = (@store ||= {}) }.new
      context[:viewer] = :someone

      expect(adapter.actor(context).user).to eq(:someone)
      expect(adapter.actor({ current_ability: :given })).to eq(:given)
    end

    it "refuses at boot a key that is not a Symbol or a String" do
      [nil, 1, []].each do |key|
        expect { adapters::Pundit.new(user_key: key) }.to raise_error(ArgumentError, /user_key/)
        expect { adapters::CanCan.new(user_key: key) }.to raise_error(ArgumentError, /user_key/)
      end
    end
  end

  describe "the rake task" do
    let(:root) { File.expand_path("../..", __dir__) }

    def run_ruby(script)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "script.rb")
        File.write(path, script)
        output, = Open3.capture2e("bundle", "exec", "ruby", "-I", File.join(root, "lib"), path, chdir: root)
        output
      end
    end

    it "loads in a Rails app with no load of its own, and runs after the app's environment" do
      output = run_ruby(<<~RUBY)
        require "rails"
        require "rake"
        require "graphql/armory"
        class ArmoryProbeApp < Rails::Application
          config.eager_load = false
          config.secret_key_base = "x" * 32
          config.logger = Logger.new(IO::NULL)
        end
        ArmoryProbeApp.initialize!
        Rake.application.init("rake", [])
        ArmoryProbeApp.load_tasks
        ran = []
        Rake::Task[:environment].enhance { ran << :environment }
        begin
          Rake::Task["graphql_armory:audit"].invoke
        rescue SystemExit => error
          puts "exit \#{error.status}"
        end
        puts "ran \#{ran.inspect}"
      RUBY

      expect(output).to include("ran [:environment]", "exit 1")
    end

    it "does not define the task twice when an app also loads it by hand" do
      output = run_ruby(<<~RUBY)
        require "rake"
        include Rake::DSL
        load "tasks/graphql_armory.rake"
        load "tasks/graphql_armory.rake"
        puts "actions \#{Rake::Task["graphql_armory:audit"].actions.size}"
      RUBY

      expect(output).to include("actions 1")
    end

    it "does not load Rails for an app that has none" do
      output = run_ruby(<<~RUBY)
        require "graphql/armory"
        puts "rails \#{defined?(::Rails).inspect}"
      RUBY

      expect(output).to include("rails nil")
    end
  end
end
