# frozen_string_literal: true

require "rails_helper"

RSpec.describe PushSubscriptionPayload do
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }

  it "validates a real synthetic curve point, retains opaque endpoint bytes and normalizes only authority for identity" do
    values = push_registration(endpoint: "https://Push.Example.Invalid:443/messages/token?opaque=ABC")
    parsed = described_class.parse(values)
    expect(parsed.payload.fetch("endpoint")).to eq(values.dig("subscription", "endpoint"))
    expect(parsed.canonical_endpoint).to eq("https://push.example.invalid/messages/token?opaque=ABC")
    expect(parsed.endpoint_origin).to eq("https://push.example.invalid")
    expect(parsed.expires_at).to be_nil
  end

  it "accepts future millisecond expiration while rejecting false, floats, past values and oversized timestamps" do
    millis = 1.day.from_now.to_i * 1000
    expect(described_class.parse(push_registration(expiration: millis)).expires_at).to eq(1.day.from_now)
    [ false, "123", 1.5, Time.current.to_i * 1000, -1, 253_402_300_800_000 ].each do |expiration|
      expect { described_class.parse(push_registration(expiration:)) }.to raise_error(Api::V1::InvalidParameter)
    end
  end

  it "rejects malformed endpoints and unexpected consent or payload fields without fetching anything" do
    [ "http://push.example.invalid/x", "https://user:secret@push.example.invalid/x", "https://push.example.invalid/x#fragment",
      "https://push.example.invalid:8443/x", "https://localhost/x", "https://127.0.0.1/x", "https://[::1]/x",
      "https://internal.local/x", "https://bad..example.invalid/x", "https://push.example.invalid/" + "x" * 2048 ].each do |endpoint|
      expect { described_class.parse(push_registration(endpoint:)) }.to raise_error(Api::V1::InvalidParameter)
    end
    [ false, "true", nil ].each do |consent|
      expect { described_class.parse(push_registration.merge("consent" => consent)) }.to raise_error(Api::V1::InvalidParameter)
    end
    expect { described_class.parse(push_registration.merge("user_id" => 1)) }.to raise_error(Api::V1::InvalidParameter)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "rejects malformed, padded, off-curve or incorrectly sized encryption material" do
    values = push_registration
    [ { "auth" => "bad" }, { "auth" => values.dig("subscription", "keys", "auth") + "==" },
      { "p256dh" => Base64.urlsafe_encode64("\x04" + "\x00" * 64, padding: false) }, { "p256dh" => "" },
      { "p256dh" => 123 }, { "unknown" => "value" } ].each do |change|
      invalid = values.deep_dup
      invalid["subscription"]["keys"].merge!(change)
      expect { described_class.parse(invalid) }.to raise_error(Api::V1::InvalidParameter)
    end
  end
end
