# frozen_string_literal: true

require_relative "ably_helper"

RSpec.describe "GraphQL::Armory::Subscriptions::Ably#publish" do
  include AblyHelper

  let(:channels) { Array.new(3) { |index| ably.channel_for(controls::Id.example(index), digest) } }

  # https://ably.com/docs/api/rest-api : a batch publish answers 200 with [{channel, messageId}, ...]; when some of
  # the inner requests fail it answers 400 with error.code 40020 and a batchResponse of per-channel results.
  def ok_entry(channel) = { "channel" => channel, "messageId" => "m-#{channel.hash.abs}" }
  def error_entry(channel, code, status) = { "channel" => channel, "error" => { "code" => code, "statusCode" => status, "message" => "x" } }

  def answer_ok(*names) = http.answer(status: 200, body: JSON.generate(names.map { |name| ok_entry(name) }))

  def answer_partial(entries)
    http.answer(status: 400, body: JSON.generate("error" => { "code" => 40_020, "statusCode" => 400, "message" => "batch" }, "batchResponse" => entries))
  end

  it "posts one batch to the host with Basic auth, one spec per message, event name and JSON data" do
    answer_ok(*channels)

    outcomes = ably(host: "rest.example.test").publish(channels.map { |name| message(name) })

    expect(statuses(outcomes)).to eq([[:ok, nil]] * 3)
    request = http.requests.first
    expect(http.requests.size).to eq(1)
    expect(request[:url]).to eq("https://rest.example.test/messages")
    expect(request[:headers]).to include("Content-Type" => "application/json", "Authorization" => "Basic #{Base64.strict_encode64(AblyHelper::KEY)}")
    body = JSON.parse(request[:body])
    expect(body.map { |spec| spec["channels"] }).to eq(channels.map { |name| [name] })
    expect(body.first["messages"]).to eq([{ "name" => "update", "data" => JSON.generate(result: { "data" => { "x" => 1 } }, more: true), "encoding" => "json" }])
  end

  it "defaults to rest.ably.io" do
    answer_ok(channel)
    ably.publish([message])

    expect(http.requests.first[:url]).to eq("https://rest.ably.io/messages")
  end

  it "keeps the secret out of the body and the URL" do
    answer_ok(channel)
    ably.publish([message])

    expect(http.requests.first.values_at(:url, :body).join).not_to include(AblyHelper::KEY_SECRET)
  end

  it "splits more messages than max_batch into several requests, and numbers outcomes across them" do
    small = ably(max_payload_bytes: 262_144)
    batch = small.capabilities.max_batch
    names = Array.new(batch + 1) { |index| small.channel_for(controls::Id.example(index), digest) }
    http.answer(status: 200, body: JSON.generate(names.first(batch).map { |name| ok_entry(name) }))

    outcomes = small.publish(names.map { |name| message(name) })

    expect(http.requests.size).to eq(2)
    expect(outcomes.map(&:index)).to eq((0..batch).to_a)
  end

  describe "outcomes" do
    it "maps a partial failure per channel: size to :refused, rate limit and 5xx to :retry, auth to :refused" do
      answer_partial([ok_entry(channels[0]), error_entry(channels[1], 40_009, 400), error_entry(channels[2], 42_910, 429)])
      expect(statuses(ably.publish(channels.map { |name| message(name) }))).to eq([[:ok, nil], [:refused, :too_large], [:retry, :rate_limited]])

      answer_partial([error_entry(channels[0], 50_000, 500), error_entry(channels[1], 40_160, 401), error_entry(channels[2], 40_000, 400)])
      expect(statuses(ably.publish(channels.map { |name| message(name) }))).to eq([[:retry, :provider_error], [:refused, :unauthorized], [:refused, :bad_request]])
    end

    it "matches results to messages by channel, in order, when a channel repeats" do
      answer_partial([error_entry(channels[0], 40_009, 400), ok_entry(channels[0])])

      outcomes = ably.publish([message(channels[0]), message(channels[0], { more: false })])

      expect(statuses(outcomes)).to eq([[:refused, :too_large], [:ok, nil]])
    end

    it "retries what the answer does not mention" do
      http.answer(status: 200, body: JSON.generate([ok_entry(channels[0])]))

      expect(statuses(ably.publish([message(channels[0]), message(channels[1])]))).to eq([[:ok, nil], [:retry, :missing_result]])
    end

    it "maps a whole-request failure to every message of the batch" do
      {
        401 => [:refused, :unauthorized], 403 => [:refused, :unauthorized], 413 => [:refused, :too_large],
        429 => [:retry, :rate_limited], 500 => [:retry, :provider_error], 503 => [:retry, :provider_error],
        400 => [:refused, :bad_request], 404 => [:refused, :bad_request]
      }.each do |status, expected|
        http.answer(status: status, body: JSON.generate("error" => { "code" => status * 100, "message" => "x" }))

        expect(statuses(ably.publish([message(channels[0]), message(channels[1])]))).to eq([expected, expected])
      end
    end

    it "retries a 2xx answer it cannot read, and a body that is not a list" do
      ["", "<html>", "null", "{}", "[1]"].each do |body|
        http.answer(status: 200, body: body)

        expect(statuses(ably.publish([message(channels[0])]))).to eq([[:retry, :bad_response]])
      end
    end

    it "turns a TransportError into :retry for the whole batch and never raises" do
      http.fail_with(subscriptions::TransportError.new("HTTP POST to rest.ably.io failed: Net::ReadTimeout"))

      expect(statuses(ably.publish([message(channels[0]), message(channels[1])]))).to eq([[:retry, :transport], [:retry, :transport]])
    end

    it "keeps going after a failed chunk: only that chunk is :retry" do
      small = ably(max_payload_bytes: 262_144)
      batch = small.capabilities.max_batch
      names = Array.new(batch + 1) { |index| small.channel_for(controls::Id.example(index), digest) }
      http.fail_with(subscriptions::TransportError.new("boom"), times: 1)
      http.answer(status: 200, body: JSON.generate([ok_entry(names.last)]))

      outcomes = small.publish(names.map { |name| message(name) })

      expect(statuses(outcomes).first(batch)).to all(eq([:retry, :transport]))
      expect(statuses(outcomes).last).to eq([:ok, nil])
    end
  end

  describe "local limits" do
    it "refuses a payload over max_payload_bytes without sending it" do
      answer_ok(channels[1])
      big = message(channels[0], { result: { "data" => "x" * 70_000 }, more: true })

      expect(statuses(ably.publish([big, message(channels[1])]))).to eq([[:refused, :too_large], [:ok, nil]])
      expect(JSON.parse(http.requests.first[:body]).map { |spec| spec["channels"] }).to eq([[channels[1]]])
    end

    it "counts bytes, not characters" do
      multibyte = message(channels[0], { result: { "data" => "é" * 40_000 }, more: true })

      expect(statuses(ably.publish([multibyte]))).to eq([[:refused, :too_large]])
      expect(http.requests).to eq([])
    end

    it "refuses a payload that does not encode as JSON" do
      nan = message(channels[0], { result: { "data" => Float::NAN } })

      expect(statuses(ably.publish([nan]))).to eq([[:refused, :unencodable]])
    end

    it "makes no request when nothing is left to send" do
      expect(ably.publish([])).to eq([])
      expect(http.requests).to eq([])
    end

    it "refuses what is not a list of Messages" do
      expect { ably.publish(["a"]) }.to raise_error(ArgumentError)
      expect { ably.publish(nil) }.to raise_error(ArgumentError)
    end
  end
end
