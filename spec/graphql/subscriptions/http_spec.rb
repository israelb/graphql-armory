# frozen_string_literal: true

require "spec_helper"
require "socket"
require "graphql/armory/subscriptions"

RSpec.describe GraphQL::Armory::Subscriptions::Http do
  let(:subscriptions) { GraphQL::Armory::Subscriptions }

  # A one-request HTTP server on a local port: it keeps what it read and answers `reply`, or nothing when `reply`
  # is nil (a provider that never answers).
  def serve(reply)
    server = TCPServer.new("127.0.0.1", 0)
    received = Queue.new
    thread = Thread.new do
      client = server.accept
      head = +""
      head << client.readpartial(4096) until head.include?("\r\n\r\n")
      headers, body = head.split("\r\n\r\n", 2)
      length = headers[/content-length: *(\d+)/i, 1].to_i
      body << client.readpartial(4096) while body.bytesize < length
      received << [headers, body]
      if reply
        client.write(reply)
        client.close
      else
        sleep 2
      end
    rescue IOError, SystemCallError
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}/apps/1/events?auth_key=k", received
  ensure
    thread&.kill
    server&.close
  end

  describe ".build" do
    it "posts the body with the headers and answers the status, body and headers" do
      reply = "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
      serve(reply) do |url, received|
        response = described_class.build(timeout: 2).post(url, '{"name":"update"}', { "Content-Type" => "application/json", "X-Test" => "1" })
        headers, body = received.pop

        expect(response).to have_attributes(status: 202, body: "{}", success?: true)
        expect(response.headers["content-type"]).to eq("application/json")
        expect(response).to be_frozen
        expect(headers).to start_with("POST /apps/1/events?auth_key=k HTTP/1.1").and(include("X-Test: 1"))
        expect(body).to eq('{"name":"update"}')
      end
    end

    it "answers an error status as a response, not an exception" do
      serve("HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") do |url, _received|
        expect(described_class.build(timeout: 2).post(url, "{}", {})).to have_attributes(status: 413, success?: false)
      end
    end

    it "raises TransportError naming the error class only when the provider does not answer in time" do
      serve(nil) do |url, _received|
        expect { described_class.build(timeout: 0.2).post(url, "{}", {}) }
          .to raise_error(subscriptions::TransportError) { |error| expect([error.message.include?("Timeout"), error.message.include?("auth_key")]).to eq([true, false]) }
      end
    end

    it "raises TransportError when nothing listens" do
      port = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }

      expect { described_class.build(timeout: 1).post("http://127.0.0.1:#{port}/", "{}", {}) }.to raise_error(subscriptions::TransportError)
    end

    it "refuses a timeout that is not a positive number and a URL that is not http or https" do
      [0, -1, nil, "5"].each { |timeout| expect { described_class.build(timeout: timeout) }.to raise_error(subscriptions::ConfigurationError) }
      expect { described_class.build.post("file:///etc/passwd", "", {}) }.to raise_error(ArgumentError)
      expect { described_class.build.post("not a url", "", {}) }.to raise_error(ArgumentError)
      expect { described_class.build.post("https://example.com/", nil, {}) }.to raise_error(ArgumentError)
      expect(described_class.build.timeout).to eq(described_class::DEFAULT_TIMEOUT)
    end
  end

  describe "Http::Null" do
    it "refuses every request" do
      expect { subscriptions::Http::Null.new.post("https://example.com/", "{}", {}) }.to raise_error(subscriptions::TransportError, /no HTTP client/)
    end
  end

  describe "Http::Substitute" do
    let(:http) { subscriptions::Http::Substitute.new }

    it "records each request and answers 200 with an empty JSON object by default" do
      response = http.post("https://api.example.com/x", "{}", { "A" => "1" })

      expect(response).to have_attributes(status: 200, body: "{}", headers: {}, success?: true)
      expect(http.requests).to eq([{ url: "https://api.example.com/x", body: "{}", headers: { "A" => "1" } }])
    end

    it "answers what it is told, then fails when told" do
      http.answer(status: 401, body: "nope", headers: { "x" => "y" })
      expect(http.post("https://a/", "", {})).to have_attributes(status: 401, body: "nope", headers: { "x" => "y" })

      http.fail_with(subscriptions::TransportError.new("timeout"), times: 1)
      expect { http.post("https://a/", "", {}) }.to raise_error(subscriptions::TransportError)
      expect(http.post("https://a/", "", {}).status).to eq(401)
      expect(http.requests.size).to eq(3)
    end
  end
end
