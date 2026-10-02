# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  it "normalizes email addresses" do
    user = build(:user, email_address: "  Reader@Example.com ")

    expect(user).to be_valid
    expect(user.email_address).to eq("reader@example.com")
  end

  it "requires a password of at least eight characters" do
    user = build(:user, password: "short", password_confirmation: "short")

    expect(user).not_to be_valid
    expect(user.errors[:password]).to include("is too short (minimum is 8 characters)")
  end
end
