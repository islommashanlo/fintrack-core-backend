# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpsAuth do
  around do |example|
    original = ENV.to_h.slice("OPS_USERNAME", "OPS_PASSWORD")
    example.run
  ensure
    %w[OPS_USERNAME OPS_PASSWORD].each { |key| ENV[key] = original[key] }
  end

  it "admits nobody when either credential is unset or blank" do
    ENV["OPS_USERNAME"] = nil
    ENV["OPS_PASSWORD"] = nil
    expect(described_class.valid?("", "")).to be(false)
    expect(described_class.valid?(nil, nil)).to be(false)

    ENV["OPS_USERNAME"] = "ops"
    ENV["OPS_PASSWORD"] = ""
    expect(described_class.valid?("ops", "")).to be(false)
  end

  it "requires both the username and the password to match" do
    ENV["OPS_USERNAME"] = "ops"
    ENV["OPS_PASSWORD"] = "secret"

    expect(described_class.valid?("ops", "secret")).to be(true)
    expect(described_class.valid?("ops", "Secret")).to be(false)
    expect(described_class.valid?("other", "secret")).to be(false)
  end
end
