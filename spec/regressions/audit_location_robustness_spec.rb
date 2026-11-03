# frozen_string_literal: true

require "rbconfig"

# A location is never worth failing the audit, nor worth pointing at the wrong class.
module AuditLocationRobustness
  Plugin = GraphQL::Armory::Authorization

  class BaseObject < GraphQL::Schema::Object
    include Plugin::Base
  end

  class Invoice < BaseObject
    field :total, String, null: true
  end

  RaisingName = Class.new(BaseObject) do
    graphql_name "RaisingName"
    field :total, String, null: true
    # Not a StandardError: an abstract `name` often raises this one.
    def self.name = raise(NotImplementedError, "no name")
  end

  IntegerName = Class.new(BaseObject) do
    graphql_name "IntegerName"
    field :total, String, null: true
    def self.name = 42
  end

  OtherName = Class.new(BaseObject) do
    graphql_name "OtherName"
    field :total, String, null: true
    def self.name = "AuditLocationRobustness::Invoice"
  end

  def self.schema(type)
    query = Class.new(BaseObject) do
      graphql_name "Query"
      authorize :none, reason: "root", covers_fields: true
      field :thing, type, null: true
    end
    Class.new(GraphQL::Schema) do
      use Plugin, adapter: Plugin::Adapters::Substitute.new
      query query
    end
  end
end

RSpec.describe "the audit's locations on odd classes" do
  let(:audit) { GraphQL::Armory::Authorization::Audit }

  def no_rule(type) = audit.(AuditLocationRobustness.schema(type)).problems.find { |problem| problem.kind == :no_rule }

  it "reports a class whose name raises, with no location" do
    expect(no_rule(AuditLocationRobustness::RaisingName).location).to be_nil
  end

  it "reports a class whose name is not a String, with no location" do
    expect(no_rule(AuditLocationRobustness::IntegerName).location).to be_nil
  end

  it "does not place a class at another constant its name points to" do
    expect(no_rule(AuditLocationRobustness::OtherName).location).to be_nil
  end

  it "loads from a directory that was removed" do
    script = "require 'tmpdir'; d = Dir.mktmpdir; Dir.chdir(d); Dir.rmdir(d); " \
             "begin; require 'graphql/armory'; puts 'loaded'; rescue Exception => e; puts e.class; end"
    output = IO.popen([RbConfig.ruby, "-e", script], err: %i[child out], &:read)

    expect(output.strip.lines.last.to_s.strip).to eq("loaded")
  end
end
