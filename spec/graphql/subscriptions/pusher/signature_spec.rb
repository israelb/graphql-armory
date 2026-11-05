# frozen_string_literal: true

require_relative "support"

RSpec.describe "GraphQL::Armory::Subscriptions::Pusher request signing" do
  include PusherSpecSupport

  let(:signature) { GraphQL::Armory::Subscriptions::Pusher::Signature }

  # https://pusher.com/docs/channels/library_auth_reference/rest-api/ (the "Authentication signature" worked example)
  it "signs the documented REST example" do
    body = '{"name":"foo","channels":["project-3"],"data":"{\"some\":\"data\"}"}'
    query = signature.query(key: app_key, secret: secret, method: "POST", path: "/apps/3/events", body: body, timestamp: 1_353_088_179)

    expect(query).to eq("auth_key=278d425bdf160c739803&auth_timestamp=1353088179&auth_version=1.0&body_md5=ec365a775a4cd0599faeb73354201b6f" \
                        "&auth_signature=da454824c97ba181a32ccc17a72625ba02771f50b50e1e7430e47a1f3f457e6c")
  end

  # https://pusher.com/docs/channels/library_auth_reference/auth-signatures/ (the private channel example)
  it "signs the documented private channel example" do
    expect(signature.channel_auth(key: app_key, secret: secret, socket_id: "1234.1234", channel: "private-foobar"))
      .to eq("278d425bdf160c739803:58df8b0c36d6982b82c3ecf6b4662e34fe8c25bba48f5369f135bf843651c3a4")
  end

  it "signs a request without a body without body_md5" do
    query = signature.query(key: app_key, secret: secret, method: "GET", path: "/apps/3/channels", body: "", timestamp: 1)

    expect(query).not_to include("body_md5")
  end
end
