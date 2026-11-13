# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reported portfolio weights and ranks in fund comparisons" do
  include InstitutionalReadHelpers
  include OpenapiResponses
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:first) { create(:institutional_filer) }
  let(:second) { create(:institutional_filer) }
  let(:period) { Date.new(2026, 9, 30) }
  let(:prior) { Date.new(2026, 6, 30) }

  def report(fund, quarter: period, rows: [ {} ], **attributes)
    item = create_13f(fund:, period: quarter, filed_at: quarter == period ? 2.days.ago : Time.utc(2026, 8, 14), **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def compare(**parameters)
    get api_v1_fund_comparison_path, params: { ciks: [ first.cik, second.cik ].join(","), period: period.iso8601, **parameters }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect_documented_response(path: "/funds/compare")
    response.parsed_body
  end

  def weights(body, cik: first.cik)
    body.fetch("data").fetch("positions").map { |row| row.fetch("funds").find { |entry| entry["cik"] == cik } }
  end

  it "uses full per-fund totals independently for current and prior quarters before security/scope filters" do
    report(first, quarter: prior, rows: [ {}, { cusip: "594918104", value_reported: 300 } ])
    report(first, rows: [ { value_reported: 200 }, { cusip: "594918104", value_reported: 300 } ])
    report(second, quarter: prior, rows: [ { value_reported: 500 } ])
    report(second, rows: [ {}, { cusip: "02079K305", value_reported: 100 } ])
    body = compare(scope: "shared", cusip: "037833100")
    entry = weights(body).sole
    expect(entry).to include("rank" => 2, "prior_rank" => 2)
    expect(weights(body, cik: second.cik).sole).to include("rank" => 1, "prior_rank" => 1)
    expect(BigDecimal(entry.fetch("weight_percent"))).to eq(40)
    expect(BigDecimal(entry.fetch("prior_weight_percent"))).to eq(25)
    expect(BigDecimal(weights(body, cik: second.cik).sole.fetch("weight_percent"))).to eq(50)
    state = body.dig("data", "funds").find { |row| row["cik"] == first.cik }
    expect(state).to include("current_value_complete" => true, "prior_value_complete" => true,
      "current_portfolio_value_usd" => "500.0", "prior_portfolio_value_usd" => "400.0")
  end

  it "uses competition ties independently per fund and quarter without ranking absent keys" do
    report(first, rows: [ { value_reported: 200 }, { cusip: "594918104", value_reported: 200 },
      { cusip: "02079K305", value_reported: 0 } ])
    report(first, quarter: prior, rows: [ { value_reported: 100 }, { cusip: "594918104", value_reported: 200 } ])
    report(second, rows: [ { value_reported: 100 }, { cusip: "02079K305", value_reported: 200 } ])
    body = compare(sort: "cusip")
    entries = body.dig("data", "positions").index_by { |row| row["cusip"] }
    expect(weights(body).pluck("rank")).to eq([ 3, 1, 1 ])
    expect(entries.fetch("037833100").fetch("funds").find { |row| row["cik"] == first.cik }).to include("rank" => 1, "prior_rank" => 2)
    expect(weights(body, cik: second.cik).pluck("rank")).to eq([ 1, 2, nil ])
    expect(weights(body, cik: second.cik).pluck("prior_rank")).to all(be_nil)
  end

  it "withholds the incomplete side including normalization errors outside the displayed filter" do
    previous = report(first, quarter: prior)
    report(first, rows: [ {}, { cusip: "594918104", value_usd: nil } ])
    report(second, quarter: prior)
    report(second)
    body = compare(cusip: "037833100")
    expect(weights(body).sole).to include("weight_percent" => nil, "rank" => nil, "prior_rank" => 1, "current_value_complete" => false, "prior_value_complete" => true)
    expect(BigDecimal(weights(body).sole.fetch("prior_weight_percent"))).to eq(100)
    state = body.dig("data", "funds").find { |row| row["cik"] == first.cik }
    expect(state).to include("current_available" => true, "current_value_complete" => false, "current_portfolio_value_usd" => nil)
    previous.update!(suspect: true)
    expect(weights(compare(cusip: "037833100")).sole).to include("prior_weight_percent" => nil, "prior_rank" => nil)
  end

  it "checks cover totals, units, row integrity and missing originals with the shared strict policy" do
    source = report(first)
    report(second)
    source.update!(table_entry_total: 2)
    expect(weights(compare).sole).to include("weight_percent" => nil, "rank" => nil)
    source.update!(table_entry_total: 1)
    holding = source.institutional_holdings.sole
    holding.update!(value_usd: 1000)
    expect(weights(compare).sole).to include("weight_percent" => nil, "rank" => nil)
    holding.update!(value_usd: 100, shares: 0)
    expect(weights(compare).sole).to include("weight_percent" => nil, "rank" => nil)
    holding.update!(shares: 10)
    source.update!(amendment_type: "RESTATEMENT", submission_type: "13F-HR/A")
    source.filing.update!(form_type: "13F-HR/A")
    expect(weights(compare).sole).to include("weight_percent" => nil, "rank" => nil)
  end

  it "resolves restatements and additions while grouping repeated keys and separating options/principal" do
    report(first, rows: [ { value_reported: 999 } ])
    report(first, amendment_type: "RESTATEMENT", filed_at: 1.day.ago,
      rows: [ { value_reported: 100 }, { put_call: "PUT", value_reported: 50 }, { share_type: "PRN", value_reported: 50 } ])
    report(first, amendment_type: "NEW HOLDINGS", filed_at: 1.hour.ago, rows: [ { value_reported: 50 } ])
    report(second)
    body = compare
    state = body.dig("data", "funds").find { |row| row["cik"] == first.cik }
    expect(state).to include("current_value_complete" => true, "current_portfolio_value_usd" => "250.0")
    entries = weights(body)
    plain = entries.find { |entry| entry["row_count"] == 2 }
    expect(plain.fetch("rank")).to eq(1)
    expect(entries.pluck("rank").sort).to eq([ 1, 2, 2 ])
    expect(BigDecimal(plain.fetch("weight_percent"))).to eq(60)
    expect(entries.filter_map { |entry| entry["weight_percent"] }.map { |value| BigDecimal(value) }.sum).to eq(100)
  end

  it "keeps absent positions, valid empty reports and zero-value portfolios distinct" do
    report(first, quarter: prior)
    report(first, rows: [])
    report(second, rows: [ { cusip: "594918104", value_reported: 0 } ])
    body = compare
    state = body.dig("data", "funds").find { |row| row["cik"] == first.cik }
    expect(state).to include("current_value_complete" => true, "current_portfolio_value_usd" => "0.0")
    expect(weights(body).pluck("weight_percent")).to all(be_nil)
    expect(weights(body, cik: second.cik).pluck("weight_percent")).to all(be_nil)
    exited = body.dig("data", "positions").find { |row| row["cusip"] == "037833100" }.fetch("funds").find { |row| row["cik"] == first.cik }
    expect(exited).to include("rank" => nil, "prior_rank" => 1)
    zero = weights(body, cik: second.cik).find { |entry| entry["present"] }
    expect(zero).to include("rank" => 1, "prior_rank" => nil)
    expect(exited.fetch("weight_percent")).to be_nil
    expect(BigDecimal(exited.fetch("prior_weight_percent"))).to eq(100)
    expect(body.dig("data", "funds").find { |row| row["cik"] == second.cik }.fetch("prior_value_complete")).to be(false)
  end

  it "detects missing rank fields and numeric decimal drift against the published response schema" do
    report(first)
    report(second)
    body = compare
    document = YAML.safe_load_file(Rails.root.join("docs/openapi.yml"), aliases: true)
    schema = document.fetch("paths").fetch("/funds/compare").fetch("get")
      .fetch("responses").fetch("200").fetch("content").fetch("application/json").fetch("schema")
    entry = body.fetch("data").fetch("positions").sole.fetch("funds").first
    entry.delete("rank")
    entry["value_usd"] = 100.0
    errors = ApiContract::ResponseSchema.new(document:).errors(body, schema:)
    expect(errors).to include("$.data.positions[0].funds[0].rank: required field missing",
      "$.data.positions[0].funds[0].value_usd: expected string, got Float")
  end

  it "uses first-page report and holding ceilings for denominators across continued pages" do
    source = report(first, rows: [ {}, { cusip: "594918104", value_reported: 300 } ])
    report(second, rows: [ {}, { cusip: "594918104" } ])
    first_page = compare(sort: "cusip", limit: 1)
    report(first, amendment_type: "RESTATEMENT", filed_at: Time.current, rows: [ { value_reported: 999 } ])
    create(:institutional_holding, institutional_report: source, value_reported: 999)
    continued = compare(sort: "cusip", limit: 1, cursor: first_page.dig("meta", "next_cursor"))
    expect(weights(first_page).sole.fetch("rank")).to eq(2)
    expect(weights(continued).sole.fetch("rank")).to eq(1)
    expect(BigDecimal(weights(continued).sole.fetch("weight_percent"))).to eq(75)
    expect(continued.dig("data", "funds").find { |row| row["cik"] == first.cik }.fetch("current_portfolio_value_usd")).to eq("400.0")
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
