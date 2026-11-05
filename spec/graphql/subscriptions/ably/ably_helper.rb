# frozen_string_literal: true

require "spec_helper"
require "json"
require "base64"
require "openssl"
require "graphql/armory/subscriptions"
require "graphql/armory/subscriptions/ably"

# Shared setup for the Ably specs: a key, a fixed clock and nonce, Http::Substitute, and the Ably wire shapes.
module AblyHelper
  KEY_NAME = "appId.keyId"
  KEY_SECRET = "s3cret-key_value"
  KEY = "#{KEY_NAME}:#{KEY_SECRET}"
  NOW = Time.at(1_800_000_000)
  NOW_MS = 1_800_000_000_000

  def subscriptions = GraphQL::Armory::Subscriptions
  def controls = subscriptions::Controls
  def http = @http ||= subscriptions::Http::Substitute.new
  def clock = -> { NOW }
  def nonce = -> { "fixed-nonce-0123456789" }
  def digest = controls::Digest.example("viewer")
  def id = controls::Id.example
  def ably(**options) = subscriptions::Ably.build(key: KEY, http: http, clock: clock, nonce: nonce, **options)
  def channel = ably.channel_for(id, digest)

  def message(channel = self.channel, payload = { result: { "data" => { "x" => 1 } }, more: true })
    subscriptions::Message.new(channel: channel, payload: payload)
  end

  def statuses(outcomes) = outcomes.map { |outcome| [outcome.status, outcome.reason] }

  def base64_hmac(secret, text) = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, text))
end
