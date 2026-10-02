# frozen_string_literal: true

require "rails_helper"

RSpec.describe Follow do
  it "allows one follow per user and target" do
    user = create(:user)
    create(:follow, user:, target_type: "Ticker", target_key: "ACME")
    duplicate = build(:follow, user:, target_type: "Ticker", target_key: "ACME")

    expect(duplicate).to be_invalid
    expect(duplicate.errors[:target_key]).to include("has already been taken")
  end

  it "restricts follow target types" do
    follow = build(:follow, target_type: "Unknown")

    expect(follow).to be_invalid
    expect(follow.errors[:target_type]).to include("is not included in the list")
  end
end
