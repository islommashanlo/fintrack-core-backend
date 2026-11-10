# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApiRateLimiter do
  it "restores access when Redis expires the fixed window" do
    args = { scope: "expiry_spec", identifier: "example", limit: 1, window: 1.second }
    described_class.check!(**args)
    expect { described_class.check!(**args) }.to raise_error(ApiRateLimiter::Limited)
    sleep 1.05
    expect { described_class.check!(**args) }.not_to raise_error
  end
end
