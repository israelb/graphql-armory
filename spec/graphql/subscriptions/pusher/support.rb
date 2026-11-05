# frozen_string_literal: true

require "spec_helper"
require "graphql/armory/subscriptions"
require "graphql/armory/subscriptions/pusher"
require "openssl"
require "digest"
require "json"
require "stringio"
require "uri"

# Shared setup for the Pusher specs: a built transport over Http::Substitute and a fixed clock.
module PusherSpecSupport
  # Pusher's documented example app (https://pusher.com/docs/channels/library_auth_reference/auth-signatures/).
  KEY = "278d425bdf160c739803"
  SECRET = "7ad3773142a6692b25b8"
  APP_ID = "3"
  NOW = 1_353_088_179

  def secret = SECRET
  def app_key = KEY
  def app_id = APP_ID
  def now = NOW
  def subscriptions = GraphQL::Armory::Subscriptions
  def http = @http ||= subscriptions::Http::Substitute.new
  def clock = -> { Time.at(NOW) }
  def id(index = 0) = subscriptions::Controls::Id.example(index)
  def digest = subscriptions::Controls::Digest.example("viewer")

  def build(**options)
    subscriptions::Pusher.build(app_id: APP_ID, key: KEY, secret: SECRET, http: http, clock: clock, **options)
  end

  def transport = @transport ||= build

  def message(channel = transport.channel_for(id, digest), payload = { result: { "data" => { "x" => 1 } }, more: true })
    subscriptions::Message.new(channel: channel, payload: payload)
  end

  def hmac(text) = OpenSSL::HMAC.hexdigest("SHA256", SECRET, text)

  def rack_env(body, key: KEY, signature: hmac(body), extra: {})
    env = { "rack.input" => StringIO.new(body), "CONTENT_LENGTH" => body.bytesize.to_s, "REQUEST_METHOD" => "POST" }
    env["HTTP_X_PUSHER_KEY"] = key if key
    env["HTTP_X_PUSHER_SIGNATURE"] = signature if signature
    env.merge(extra)
  end

  def webhook_body(channels, name: "channel_vacated", time_ms: NOW * 1000)
    JSON.generate("time_ms" => time_ms, "events" => channels.map { |channel| { "name" => name, "channel" => channel } })
  end
end
