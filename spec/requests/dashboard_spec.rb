# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard" do
  let(:signals) { instance_double(InsiderSignals) }

  before do
    allow(InsiderSignals).to receive(:new).and_return(signals)
    allow(signals).to receive(:recent_purchases).and_return([
      {
        "issuer_ticker" => "ACME", "issuer_name" => "Acme Corp", "insider_name" => "Jane Doe",
        "officer_title" => "Chief Executive Officer", "filed_at" => Time.zone.parse("2026-10-01 15:00"),
        "shares" => 500, "price" => BigDecimal("25"), "price_suspect" => false,
        "value" => BigDecimal("12500")
      }
    ])
    allow(signals).to receive(:cluster_buys).and_return([
      {
        "issuer_ticker" => "ACME", "issuer_name" => "Acme Corp", "insiders" => 3,
        "purchases" => 5, "value" => BigDecimal("50000")
      }
    ])
    allow(signals).to receive(:top_insiders).and_return([
      { "insider_name" => "Jane Doe", "purchases" => 4, "issuers" => 2, "value" => BigDecimal("75000") }
    ])
  end

  it "shows the filing signals dashboard" do
    travel_to Time.utc(2026, 10, 2, 12, 0) do
      get root_path
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Recent insider purchases", "Institutional whale flow", "Acme Corp", "Jane Doe",
                                     "$12,500.00", "Monday, November 16, 2026")
    expect(response.body).to include("FilingsIntel presents information as reported in SEC filings")
  end

  it "shows recent activity from the signed-in user's follows" do
    user = create(:user, email_address: "reader@example.com", password: "password123")
    followed = instance_double(FollowedActivity)
    allow(FollowedActivity).to receive(:new).and_return(followed)
    allow(followed).to receive(:recent).and_return([
      { "label" => "Jane Doe", "target_type" => "Insider", "target_key" => "0000000456",
        "activity_source" => "Form 4", "activity_kind" => "P", "filed_at" => Time.current,
        "issuer_ticker" => "ACME", "value" => BigDecimal("1000"), "price_suspect" => false }
    ])

    post session_path, params: { email_address: user.email_address, password: "password123" }
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Recent followed activity", "Jane Doe", "Manage watchlist")
  end
end
