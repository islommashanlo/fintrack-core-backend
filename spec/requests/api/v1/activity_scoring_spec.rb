# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 activity scoring diagnostics" do
  include OpenapiResponses
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 10, 20)) { example.run } }

  it "exposes explicit missing input coverage and measured factors on insider details only" do
    filing = create(:filing, filed_at: 1.day.ago)
    transaction = create(:insider_transaction, filing:, transaction_date: 2.days.ago.to_date,
      shares_owned_following: 200, is_director: true)
    get api_v1_activity_event_path("insider_#{transaction.id}")
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include("score" => nil, "level" => nil, "reasons" => [])
    expect(data.fetch("scoring")).to include("status" => "incomplete", "methodology_version" => "1.5-draft",
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
    market = data.fetch("score_breakdown").find { |factor| factor.fetch("id") == "issuer_scale_and_liquidity" }
    expect(market.fetch("unavailable_reason")).to eq("unsupported_transaction")
    expect(market.dig("inputs", "requirements", "coverage_evaluated")).to be(false)
    expect(data.fetch("score_breakdown")).to all(include("value" => nil, "points" => nil))
  end

  it "returns institutional factor diagnostics with source coverage and keeps feed scores unavailable" do
    fund = create(:institutional_filer)
    previous = create_13f(fund:, period: Date.new(2026, 3, 31))
    current = create_13f(fund:)
    create(:institutional_holding, institutional_report: previous, shares: 100, value_reported: 1000, value_usd: 1000)
    create(:institutional_holding, institutional_report: current, shares: 150, value_reported: 1500, value_usd: 1500)
    previous.update!(table_value_total: 1000)
    current.update!(table_value_total: 1500)
    get api_v1_activity_path, params: { source: "institutional" }
    feed = response.parsed_body.fetch("data").sole
    expect(feed).to include("score" => nil, "score_breakdown" => [])
    expect(feed).not_to have_key("scoring")
    get api_v1_activity_event_path(feed.fetch("id"))
    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include("score" => nil, "level" => nil, "reasons" => [], "accession" => current.filing.accession_no)
    expect(data.dig("scoring", "source_coverage")).to include("reports_complete" => true, "values_complete" => true,
      "report_ids" => [ previous.id, current.id ])
    expect(data.dig("scoring", "coverage")).to include("available_weight" => 50,
      "missing_factors" => %w[own_history issuer_scale_and_liquidity])
    factors = data.fetch("score_breakdown").index_by { |factor| factor.fetch("id") }
    expect(factors.fetch("position_size_change")).to include("value" => "0.5", "points" => "10.0")
    expect(factors.fetch("issuer_scale_and_liquidity")).to include("value" => nil, "points" => nil)
    expect(factors.dig("issuer_scale_and_liquidity", "inputs", "requirements", "coverage_evaluated")).to be(false)
    before = data.slice("scoring", "score_breakdown")
    restatement = create_13f(fund:, amendment_type: "RESTATEMENT", filed_at: 1.day.ago)
    create(:institutional_holding, institutional_report: restatement, shares: 5)
    get api_v1_activity_event_path(feed.fetch("id"))
    expect(response.parsed_body.fetch("data").slice("scoring", "score_breakdown")).to eq(before)
  end

  it "preserves reported institutional rows while withholding factors for incomplete sources" do
    fund = create(:institutional_filer)
    previous = create_13f(fund:, period: Date.new(2026, 3, 31))
    current = create_13f(fund:)
    create(:institutional_holding, institutional_report: previous, shares: 100)
    create(:institutional_holding, institutional_report: current, shares: 150)
    current.update!(table_entry_total: 2)
    get api_v1_activity_path, params: { source: "institutional" }
    id = response.parsed_body.fetch("data").sole.fetch("id")
    get api_v1_activity_event_path(id)
    data = response.parsed_body.fetch("data")
    expect(data.dig("scoring", "status")).to eq("ineligible")
    expect(data.dig("scoring", "source_coverage", "invalid_report_ids")).to eq([ current.id ])
    expect(data.dig("position_change", "shares_after")).to eq("150.0")
    expect(data.fetch("score_breakdown")).to all(include("value" => nil, "points" => nil))
  end
  it "keeps stored bars from implicitly activating market factors or querying price data" do
    filing = create(:filing, filed_at: 1.day.ago)
    transaction = create(:insider_transaction, filing:, transaction_date: 2.days.ago.to_date)
    series = price_series(security: create(:security, ticker: filing.issuer_ticker))
    PriceDaily.create!(**market_bars.first.to_h, price_series: series, observed_at: Time.current)
    queries = []
    observer = ->(_name, _start, _finish, _id, payload) { queries << payload.fetch(:sql) }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      get api_v1_activity_event_path("insider_#{transaction.id}")
    end
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/activity/{id}")
    expect(queries.join(" ")).not_to match(/\b(?:prices_daily|price_series)\b/)
    data = response.parsed_body.fetch("data")
    expect(data).to include("score" => nil, "level" => nil, "reasons" => [])
    market = data.fetch("score_breakdown").find { |factor| factor.fetch("id") == "issuer_scale_and_liquidity" }
    expect(market).to include("status" => "unavailable", "value" => nil, "points" => nil)
    expect(market.dig("inputs", "requirements")).to eq(ActivityMethodology.definition.dig("score", "market_input_requirements"))
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
