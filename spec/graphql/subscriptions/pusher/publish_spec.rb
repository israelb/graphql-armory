# frozen_string_literal: true

require_relative "support"

RSpec.describe "GraphQL::Armory::Subscriptions::Pusher#publish" do
  include PusherSpecSupport

  def request = http.requests.last
  def url = URI.parse(request[:url])
  def query = URI.decode_www_form(url.query).to_h
  def batch = JSON.parse(request[:body])["batch"]

  it "posts one signed batch_events request to the cluster host" do
    transport.publish([message])

    expect([url.scheme, url.host, url.path]).to eq(["https", "api-mt1.pusher.com", "/apps/3/batch_events"])
    expect(request[:headers]).to include("Content-Type" => "application/json")
    expect(query).to include("auth_key" => app_key, "auth_timestamp" => now.to_s, "auth_version" => "1.0", "body_md5" => Digest::MD5.hexdigest(request[:body]))
  end

  it "signs the method, path and sorted query with the secret" do
    transport.publish([message])

    unsigned = query.reject { |name, _| name == "auth_signature" }.sort.map { |name, value| "#{name}=#{value}" }.join("&")
    expect(query["auth_signature"]).to eq(hmac("POST\n/apps/3/batch_events\n#{unsigned}"))
  end

  it "sends the event name, the channel and the payload as a JSON string" do
    channel = transport.channel_for(id, digest)
    transport.publish([message(channel, { result: { "data" => { "x" => 1 } }, more: false })])

    expect(batch).to eq([{ "name" => "update", "channel" => channel, "data" => '{"result":{"data":{"x":1}},"more":false}' }])
  end

  it "uses the cluster or the host it is built with" do
    build(cluster: "eu").publish([message])
    expect(URI.parse(http.requests.last[:url]).host).to eq("api-eu.pusher.com")

    build(host: "soketi.example.test:6001", scheme: "http").publish([message])
    expect(URI.parse(http.requests.last[:url]).then { |uri| [uri.scheme, uri.host, uri.port] }).to eq(["http", "soketi.example.test", 6001])
  end

  it "answers :ok for every message of a 2xx answer" do
    outcomes = transport.publish([message, message(transport.channel_for(id(1), digest))])

    expect(outcomes.map { |outcome| [outcome.status, outcome.index] }).to eq([[:ok, 0], [:ok, 1]])
  end

  {
    413 => [:refused, :payload_rejected],
    400 => [:refused, :bad_request],
    401 => [:refused, :unauthorized],
    403 => [:refused, :forbidden],
    404 => [:refused, :client_error],
    408 => [:retry, :timeout],
    429 => [:retry, :rate_limited],
    500 => [:retry, :provider_error],
    503 => [:retry, :provider_error],
    302 => [:retry, :unexpected_status]
  }.each do |status, (outcome, reason)|
    it "answers #{outcome} (#{reason}) for a #{status}" do
      http.answer(status: status, body: "nope")

      outcomes = transport.publish([message, message])

      expect(outcomes.map { |o| [o.status, o.reason] }).to eq([[outcome, reason]] * 2)
      expect(http.requests.size).to eq(1)
    end
  end

  it "turns a TransportError into :retry outcomes without retrying inline" do
    http.fail_with(GraphQL::Armory::Subscriptions::TransportError.new("timeout"))

    outcomes = transport.publish([message])

    expect(outcomes.map { |o| [o.status, o.reason] }).to eq([[:retry, :transport_error]])
    expect(http.requests.size).to eq(1)
  end

  it "never puts the secret in an outcome" do
    http.answer(status: 401, body: "bad auth_signature #{secret}")

    expect(transport.publish([message]).map(&:inspect).join).not_to include(secret)
  end

  it "raises ArgumentError for a batch over max_batch, an empty batch or an oversized payload" do
    expect { transport.publish(Array.new(11) { message }) }.to raise_error(ArgumentError, /max_batch/)
    expect { transport.publish([]) }.to raise_error(ArgumentError)
    expect { transport.publish(["x"]) }.to raise_error(ArgumentError)
    expect { transport.publish([message(transport.channel_for(id, digest), { result: "x" * 10_240 })]) }.to raise_error(ArgumentError, /max_payload_bytes/)
    expect(http.requests).to be_empty
  end

  it "measures the payload in bytes, not characters, and accepts exactly the limit" do
    exact = "é" * ((10_240 - JSON.generate({ result: "" }).bytesize) / 2)
    channel = transport.channel_for(id, digest)

    expect(JSON.generate({ result: exact }).bytesize).to be <= 10_240
    expect(transport.publish([message(channel, { result: exact })]).first).to be_ok
    expect { transport.publish([message(channel, { result: "#{exact}éé" })]) }.to raise_error(ArgumentError)
  end

  it "keeps a compressed_result payload as given" do
    compressed = build(compress: true)
    compressed.publish([message(compressed.channel_for(id, digest), { compressed_result: "eJyrVkrNS1ayUspPSVWqBQA=", more: true })])

    expect(JSON.parse(JSON.parse(http.requests.last[:body])["batch"].first["data"])).to eq("compressed_result" => "eJyrVkrNS1ayUspPSVWqBQA=", "more" => true)
  end
end
