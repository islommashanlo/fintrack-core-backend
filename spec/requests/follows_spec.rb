# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Follows" do
  let!(:user) { create(:user, email_address: "reader@example.com", password: "password123") }

  before do
    post session_path, params: { email_address: user.email_address, password: "password123" }
  end

  it "follows and unfollows a ticker" do
    filing = create(:filing, issuer_ticker: "ACME", issuer_name: "Acme Corp")
    create(:insider_transaction, filing:, insider_cik: "0000000456", insider_name: "Jane Doe")

    expect do
      post follows_path, params: { follow: { target_type: "Ticker", target_key: "ACME" } }
    end.to change(Follow, :count).by(1)

    follow = Follow.last
    expect(follow).to have_attributes(user:, target_type: "Ticker", target_key: "ACME")

    expect do
      delete follow_path(follow)
    end.to change(Follow, :count).by(-1)
  end

  it "rejects an unknown target" do
    expect do
      post follows_path, params: { follow: { target_type: "Ticker", target_key: "MISSING" } }
    end.not_to change(Follow, :count)

    expect(response).to redirect_to(discover_path)
  end
end
