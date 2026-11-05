# frozen_string_literal: true

require "spec_helper"

RSpec.describe GraphQL::Armory::Caching::Base do
  let(:caching) { GraphQL::Armory::Caching }

  let(:base_field) { Class.new(GraphQL::Schema::Field) { include GraphQL::Armory::Caching::Base } }
  let(:base_object) do
    field_class = base_field
    Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Caching::Base
      field_class field_class
    end
  end

  def object(name, &block)
    Class.new(base_object) do
      graphql_name name
      instance_eval(&block)
    end
  end

  it "applies a type's cache_fields to the fields it declares" do
    type = object("Product") do
      cache_fields ttl: 300, scope: :public, tags: ["catalog"], reason: "public catalog"
      field :name, String
    end

    expect(type.fields["name"].armory_cache).to eq(caching::Declaration.build(ttl: 300, scope: :public, tags: ["catalog"], reason: "public catalog"))
  end

  it "completes a field's partial declaration from its owner, joining the tags" do
    type = object("Product") do
      cache_fields ttl: 300, scope: :public, tags: ["catalog"], reason: "public catalog"
      field :price, String, cache: { ttl: 60, tags: ["pricing"] }
    end

    declaration = type.fields["price"].armory_cache
    expect([declaration.ttl, declaration.scope, declaration.tags]).to eq([60, :public, %w[catalog pricing]])
  end

  it "refuses a field that widens its owner's TTL or scope, at definition" do
    expect do
      object("Invoice") do
        cache_fields ttl: 30
        field :number, String, cache: { ttl: 60 }
      end
    end.to raise_error(caching::ConfigurationError, /Invoice\.number: .*ttl: 60 is longer/)

    expect do
      object("Invoice") do
        cache_fields ttl: 30
        field :number, String, cache: { scope: :public, reason: "x" }
      end
    end.to raise_error(caching::ConfigurationError, /wider/)
  end

  it "refuses a widening field when cache_fields comes after it" do
    expect do
      object("Invoice") do
        field :number, String, cache: { ttl: 60 }
        cache_fields ttl: 30
      end
    end.to raise_error(caching::ConfigurationError, /Invoice: .*ttl: 60 is longer/)
  end

  it "requires a reason for :public and refuses unknown options" do
    expect { object("Product") { cache_fields ttl: 60, scope: :public } }.to raise_error(caching::ConfigurationError, /reason/)
    expect { object("Product") { field :name, String, cache: { ttl: 60, scope: :public } } }.to raise_error(caching::ConfigurationError, /reason/)
    expect { object("Product") { field :name, String, cache: { ttl: 60, vary: :locale } } }.to raise_error(caching::ConfigurationError, /unknown: vary/)
    expect { object("Product") { field :name, String, cache: true } }.to raise_error(caching::ConfigurationError)
  end

  it "keeps cache: false whatever the owner declares" do
    type = object("Product") do
      cache_fields ttl: 300, scope: :public, reason: "public"
      field :stock_level, Integer, cache: false
    end

    expect(type.fields["stockLevel"].armory_cache).to be_forbidden
  end

  it "leaves a field undeclared when neither it nor its owner declares anything" do
    expect(object("Product") { field :name, String }.fields["name"].armory_cache).to be_nil
  end

  it "keeps an inherited field's declaring owner's default, not the subclass's wider one" do
    parent = object("Parent") { field :secret, String }
    child = Class.new(parent) do
      graphql_name "Child"
      cache_fields ttl: 3600, scope: :public, reason: "the child is public"
      field :name, String
    end

    expect(child.fields["secret"].armory_cache).to be_nil
    expect(child.fields["name"].armory_cache.ttl).to eq(3600)
    expect(child.armory_cache_fields).not_to be_nil
    expect(parent.armory_cache_fields).to be_nil
  end

  it "lets an interface declare a default for its own fields" do
    field_class = base_field
    interface = Module.new do
      include GraphQL::Schema::Interface
      include GraphQL::Armory::Caching::Base
      graphql_name "Named"
      field_class field_class
      cache_fields ttl: 120, scope: :public, reason: "names are public"
      field :name, String
    end

    expect(interface.fields["name"].armory_cache.ttl).to eq(120)
  end

  it "lets a directive declare itself cache_safe with a reason, not inherited" do
    directive = Class.new(GraphQL::Schema::Directive) do
      include GraphQL::Armory::Caching::Base
      graphql_name "hint"
      locations GraphQL::Schema::Directive::FIELD
      cache_safe reason: "a client hint"
    end

    expect(directive.armory_cache_safe?).to be(true)
    expect(Class.new(directive) { graphql_name "hint2" }.armory_cache_safe?).to be(false)
    expect { Class.new(GraphQL::Schema::Directive) { include GraphQL::Armory::Caching::Base; graphql_name "x"; cache_safe reason: "" } }
      .to raise_error(caching::ConfigurationError)
  end

  it "refuses classes it has nothing to declare on" do
    expect { Class.new(GraphQL::Schema::Enum) { include GraphQL::Armory::Caching::Base } }.to raise_error(ArgumentError, /field, object, interface or directive/)
  end

  it "composes with Authorization's field keywords" do
    field_class = Class.new(GraphQL::Schema::Field) do
      include GraphQL::Armory::Authorization::Base
      include GraphQL::Armory::Caching::Base
    end
    type = Class.new(GraphQL::Schema::Object) do
      include GraphQL::Armory::Authorization::Base
      include GraphQL::Armory::Caching::Base
      field_class field_class
      graphql_name "Product"
      field :name, String, authorize: :none, reason: "public", cache: { ttl: 60, scope: :public, reason: "public" }
    end

    expect(type.fields["name"].armory_cache.ttl).to eq(60)
    expect(type.fields["name"].armory_declared).to eq(:none)
  end
end
