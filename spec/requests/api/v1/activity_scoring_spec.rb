# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 activity scoring diagnostics" do
  around { |example| travel_to(Time.utc(2026, 11, 10, 20)) { example.run } }

  it "exposes explicit missing input coverage and measured factors on insider details only" do
    filing = create(:filing, filed_at: 1.day.ago)
    transaction = create(:insider_transaction, filing:, transaction_date: 2.days.ago.to_date,
      shares_owned_following: 200, is_director: true)
    get api_v1_activity_event_path("insider_#{transaction.id}")
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include("score" => nil, "level" => nil, "reasons" => [])
    expect(data.fetch("scoring")).to include("status" => "incomplete", "methodology_version" => "1.1-draft",
      "evaluated_at" => filing.filed_at.as_json)
    expect(data.dig("scoring", "coverage")).to include("available_weight" => 50, "required_weight" => 100,
      "missing_factors" => %w[own_history issuer_scale_and_liquidity])
    breakdown = data.fetch("score_breakdown").index_by { |factor| factor.fetch("id") }
    expect(breakdown.fetch("reported_context")).to include("value" => "0.75", "points" => "11.25")
    expect(breakdown.fetch("issuer_scale_and_liquidity")).to include("value" => nil, "points" => nil,
      "unavailable_reason" => "market_inputs_unavailable")
    expect(data).to include("accession" => filing.accession_no, "sec_url" => filing.sec_url)

    get api_v1_activity_path
    expect(response.parsed_body.fetch("data").sole).to include("score_breakdown" => [], "score" => nil)
    expect(response.parsed_body.fetch("data").sole).not_to have_key("scoring")
    expect(response.parsed_body.dig("meta", "scoring_available")).to be(false)
  end

  it "keeps historical event factors stable after a later amendment and a new participant" do
    original = create(:filing, filed_at: 3.days.ago)
    transaction = create(:insider_transaction, filing: original, transaction_date: 4.days.ago.to_date)
    get api_v1_activity_event_path("insider_#{transaction.id}")
    before = response.parsed_body.fetch("data").slice("scoring", "score_breakdown")
    amendment = create(:filing, form_type: "4/A", filed_at: 1.day.ago, amends_accession_no: original.accession_no)
    create(:insider_transaction, filing: amendment, shares: 1000)
    create(:insider_transaction, filing: create(:filing, filed_at: 2.days.ago), insider_cik: "0000000999")
    get api_v1_activity_event_path("insider_#{transaction.id}")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").slice("scoring", "score_breakdown")).to eq(before)
  end

  it "retains an administrative event's raw values and identifies unsupported scoring" do
    transaction = create(:insider_transaction, transaction_code: "A", price: nil)
    get api_v1_activity_event_path("insider_#{transaction.id}")
    data = response.parsed_body.fetch("data")
    expect(data.dig("scoring", "status")).to eq("ineligible")
    expect(data.dig("scoring", "eligibility_reason")).to eq("unsupported_transaction")
    expect(data.dig("transaction", "transaction_code")).to eq("A")
    expect(data.fetch("score_breakdown")).to all(include("value" => nil, "points" => nil))
  end
end
