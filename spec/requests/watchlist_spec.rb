# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist" do
  let!(:user) { create(:user, email_address: "reader@example.com", password: "password123") }

  it "requires authentication" do
    get watchlist_path

    expect(response).to redirect_to(new_session_path)
  end

  it "shows the signed-in user's follows" do
    post session_path, params: { email_address: user.email_address, password: "password123" }
    create(:follow, user:, target_type: "Ticker", target_key: "ACME")

    get watchlist_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Profiles on your watchlist", "ACME", "Unfollow", "Data from public SEC filings")
  end
end
