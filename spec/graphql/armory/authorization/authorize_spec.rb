# frozen_string_literal: true

RSpec.describe GraphQL::Armory::Authorization::Authorize do
  let(:authorization) { GraphQL::Armory::Authorization }
  let(:controls) { authorization::Controls }
  let(:context) { controls::Context.example }
  let(:subject_object) { controls::Subject.example }
  let(:rule) { controls::Rule.example }
  let(:adapters) { authorization::Adapters }

  def authorize_with(adapter, telemetry: authorization::Telemetry::Substitute.new, memo: authorization::Memo.new)
    described_class.new(adapter: adapter, memo: memo, telemetry: telemetry)
  end

  it "denies everything when nothing was configured" do
    expect(described_class.new.(subject_object, rule, context)).to be(false)
  end

  it "allows what the adapter allows" do
    authorize = authorize_with(adapters::Substitute.new(allow: true))

    expect(authorize.(subject_object, rule, context)).to be(true)
  end

  it "denies what the adapter denies" do
    authorize = authorize_with(adapters::Substitute.new(allow: false))

    expect(authorize.(subject_object, rule, context)).to be(false)
  end

  it "asks the adapter on behalf of the actor of the context" do
    adapter = adapters::Substitute.new(allow: true, actor: :alice)

    authorize_with(adapter).(subject_object, rule, context)

    expect(adapter.asked).to eq([[:alice, subject_object, rule]])
  end

  it "treats a nil answer as a denial" do
    authorize = authorize_with(adapters::Substitute.new(allow: nil))

    expect(authorize.(subject_object, rule, context)).to be(false)
  end

  it "refuses an adapter answer that is not true, false or nil" do
    [:yes, 1, "true", Object.new].each do |answer|
      authorize = authorize_with(adapters::Substitute.new(allow: answer))

      expect { authorize.(subject_object, rule, context) }
        .to raise_error(authorization::AdapterError, /true, false or nil/)
    end
  end

  # A policy that returns the record by mistake must not put it in a message a client may see, nor run its query.
  it "names the class of a bad answer, and never reads it" do
    answer = Struct.new(:class) { def inspect = raise("ran the query") }.new("SECRET")
    authorize = authorize_with(adapters::Substitute.new(allow: answer))

    expect { authorize.(subject_object, rule, context) }.to raise_error(authorization::AdapterError) do |error|
      expect(error.message).to include("true, false or nil")
      expect(error.message).not_to include("SECRET")
    end
  end

  it "lets a declared bypass through without asking the adapter" do
    adapter = adapters::Substitute.new(allow: false)
    bypass = authorization::Rule.none(reason: "public data")

    result = authorize_with(adapter).(subject_object, bypass, context)

    expect([result, adapter.asked]).to eq([true, []])
  end

  it "asks the adapter once per subject and rule" do
    adapter = adapters::Substitute.new(allow: true)
    authorize = authorize_with(adapter)

    2.times { authorize.(subject_object, rule, context) }

    expect(adapter.asked.size).to eq(1)
  end

  it "does not let an exception of the adapter turn into an allowance" do
    adapter = adapters::Substitute.new(raises: RuntimeError.new("boom"))

    expect { authorize_with(adapter).(subject_object, rule, context) }.to raise_error(RuntimeError, "boom")
  end

  describe "telemetry" do
    it "records a denial without record attributes" do
      telemetry = authorization::Telemetry::Substitute.new

      authorize_with(adapters::Substitute.new(allow: false), telemetry: telemetry).(subject_object, rule, context)

      expect(telemetry.recorded).to eq([[:denied, { type: subject_object.class.name, action: rule.action }]])
    end

    it "records an allowance" do
      telemetry = authorization::Telemetry::Substitute.new

      authorize_with(adapters::Substitute.new(allow: true), telemetry: telemetry).(subject_object, rule, context)

      expect(telemetry.recorded.map(&:first)).to eq([:allowed])
    end

    it "records a bypass with its reason" do
      telemetry = authorization::Telemetry::Substitute.new
      bypass = authorization::Rule.none(reason: "public data")

      authorize_with(adapters::Substitute.new, telemetry: telemetry).(subject_object, bypass, context)

      expect(telemetry.recorded).to eq([[:bypassed, { type: subject_object.class.name, reason: "public data" }]])
    end
  end

  describe ".call" do
    it "builds with the real wiring and answers" do
      adapter = adapters::Substitute.new(allow: true)

      expect(described_class.(subject_object, rule, context, adapter: adapter)).to be(true)
    end

    it "remembers answers across calls of the same context" do
      adapter = adapters::Substitute.new(allow: true)

      2.times { described_class.(subject_object, rule, context, adapter: adapter) }

      expect(adapter.asked.size).to eq(1)
    end
  end

  describe "Substitute" do
    it "answers what it was told and keeps the calls" do
      substitute = described_class::Substitute.new(answer: true)

      result = substitute.(subject_object, rule, context)

      expect([result, substitute.calls]).to eq([true, [[subject_object, rule]]])
    end
  end
end
