# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fund reported portfolio analytics" do
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }

  def report(rows: [ {} ], **attributes)
    item = create_13f(fund:, **attributes)
    holdings = rows.map do |row|
      value = row.fetch(:value_reported, 100)
      create(:institutional_holding, institutional_report: item, value_reported: value, value_usd: value, **row)
    end
    item.update!(table_entry_total: holdings.length, table_value_total: holdings.sum(&:value_reported))
    item
  end

  def fetch(**parameters)
    get holdings_api_v1_fund_path(fund.cik), params: parameters
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def portfolio(body)
    body.fetch("meta").fetch("portfolio")
  end

  it "groups repeated rows without merging options or principal amounts and uses competition ranks" do
    item = report(rows: [ { value_reported: 100 }, { value_reported: 50, investment_discretion: "OTHER" },
      { value_reported: 150, cusip: "594918104" }, { value_reported: 50, put_call: "PUT" },
      { value_reported: 50, share_type: "PRN" } ])
    body = fetch(sort: "row_sequence")
    expect(portfolio(body)).to include("complete" => true, "holding_row_count" => 5, "position_count" => 4,
      "report_ids" => [ item.id ], "incomplete_report_ids" => [], "total_value_usd" => "400.0", "known_value_usd" => "400.0")
    positions = body.fetch("data").pluck("position")
    expect(positions.first(3).pluck("rank")).to eq([ 1, 1, 1 ])
    expect(positions.last(2).pluck("rank")).to eq([ 3, 3 ])
    expect(positions.first).to include("row_count" => 2, "value_usd" => "150.0")
    expect(BigDecimal(positions.first.fetch("weight_percent"))).to eq(BigDecimal("37.5"))
    expect(body.fetch("data").first).to include("value_reported" => "100.0", "value_usd" => "100.0")
  end

  it "keeps full-portfolio denominators and ranks through filtering, pagination and later ingestion" do
    item = report(rows: [ { value_reported: 100 }, { cusip: "594918104", value_reported: 300 },
      { cusip: "02079K305", value_reported: 100 } ])
    body = fetch(cusip: "037833100")
    expect(body.dig("data", 0, "position", "rank")).to eq(2)
    expect(BigDecimal(body.dig("data", 0, "position", "weight_percent"))).to eq(20)
    body = fetch(limit: 1, sort: "row_sequence")
    cursor = body.dig("meta", "next_cursor")
    replacement = report(filed_at: Time.current, amendment_type: "RESTATEMENT", rows: [ { value_reported: 999 } ])
    create(:institutional_holding, institutional_report: item, cusip: "023135106", value_reported: 999)
    next_body = fetch(limit: 1, sort: "row_sequence", cursor:)
    expect(portfolio(next_body)).to eq(portfolio(body))
    expect(portfolio(next_body).fetch("report_ids")).not_to include(replacement.id)
    expect(BigDecimal(next_body.dig("data", 0, "position", "weight_percent"))).to eq(60)
  end

  it "uses restatements plus later additions and excludes future reports, failed sources and other funds" do
    report(rows: [ { value_reported: 999 } ])
    base = report(filed_at: Time.utc(2026, 8, 15), amendment_type: "RESTATEMENT", rows: [ { value_reported: 200 } ])
    addition = report(filed_at: Time.utc(2026, 8, 16), amendment_type: "NEW HOLDINGS", rows: [ {}, { cusip: "594918104" } ])
    report(filed_at: 1.day.from_now, amendment_type: "RESTATEMENT")
    failed = report(filed_at: Time.current, amendment_type: "RESTATEMENT")
    failed.filing.update!(parse_status: "failed")
    create(:institutional_holding, institutional_report: create_13f(fund: create(:institutional_filer)))
    body = fetch
    expect(portfolio(body)).to include("complete" => true, "total_value_usd" => "400.0", "report_ids" => [ base.id, addition.id ])
    same_key = body.fetch("data").select { |row| row["cusip"] == "037833100" }
    expect(same_key.pluck("position")).to all(include("row_count" => 2, "value_usd" => "300.0", "rank" => 1))
    expect(body.fetch("data").find { |row| row["cusip"] == "594918104" }.dig("position", "rank")).to eq(2)
  end

  it "normalizes historic thousands separately from the raw reported values" do
    report(cover_value_unit: "thousands", rows: [ { value_reported: BigDecimal("1.25"), value_unit: "thousands", value_usd: 1250 } ])
    body = fetch
    expect(portfolio(body)).to include("complete" => true, "total_value_usd" => "1250.0")
    expect(body.fetch("data").first).to include("value_reported" => "1.25", "value_usd" => "1250.0")
    expect(BigDecimal(body.dig("data", 0, "position", "weight_percent"))).to eq(100)
  end

  it "withholds every rank and weight when a value is unknown, including outside a filter" do
    item = report(rows: [ {}, { cusip: "594918104", value_usd: nil } ])
    body = fetch(cusip: "037833100")
    expect(portfolio(body)).to include("complete" => false, "known_value_usd" => "100.0", "total_value_usd" => nil,
      "incomplete_report_ids" => [ item.id ])
    expect(body.dig("data", 0, "position")).to include("rank" => nil, "weight_percent" => nil, "value_usd" => "100.0")
    expect(fetch(cusip: "594918104").dig("data", 0, "position", "value_usd")).to be_nil
  end

  it "withholds analytics for suspect rows/reports, normalization errors and mismatched cover totals" do
    item = report
    holding = item.institutional_holdings.first
    [ { suspect: true }, { table_entry_total: 2 }, { table_value_total: 999 } ].each do |attributes|
      item.update!(attributes)
      expect(portfolio(fetch).fetch("complete")).to be(false)
      item.update!(suspect: false, table_entry_total: 1, table_value_total: 100)
    end
    [ { suspect: true }, { value_usd: 1000 }, { value_unit: "thousands" }, { shares: 0 } ].each do |attributes|
      holding.update!(attributes)
      expect(fetch.dig("data", 0, "position")).to include("rank" => nil, "weight_percent" => nil)
      holding.update!(suspect: false, value_usd: 100, value_unit: "whole_dollars", shares: 10)
    end
  end

  it "retains malformed rows but excludes their grouping and marks the portfolio incomplete" do
    report(rows: [ {}, { cusip: "BAD" } ])
    body = fetch
    expect(portfolio(body)).to include("complete" => false, "holding_row_count" => 2, "position_count" => 1)
    expect(body.fetch("data").find { |row| row["cusip"] == "BAD" }.fetch("position")).to be_nil
  end

  it "keeps zero totals distinct from unknown weights" do
    report(rows: [ { value_reported: 0 } ])
    body = fetch
    expect(portfolio(body)).to include("complete" => true, "total_value_usd" => "0.0")
    expect(body.dig("data", 0, "position")).to include("rank" => 1, "weight_percent" => nil)
  end

  it "does not establish a portfolio from notices or unresolved additions" do
    report(period: Date.new(2026, 9, 30), submission_type: "13F-NT", report_type: "13F NOTICE", rows: [])
    report(period: Date.new(2026, 6, 30), amendment_type: "NEW HOLDINGS")
    [ "2026-09-30", "2026-06-30" ].each do |period|
      body = fetch(period:)
      expect(body.fetch("data")).to eq([])
      expect(portfolio(body)).to include("complete" => false, "total_value_usd" => nil, "report_ids" => [], "report_count" => 0)
    end
  end

  it "reports valid empty portfolios without inventing holdings" do
    empty = report(rows: [])
    body = fetch
    expect(body.fetch("data")).to eq([])
    expect(portfolio(body)).to include("complete" => true, "total_value_usd" => "0.0", "position_count" => 0, "report_ids" => [ empty.id ])
  end

  it "returns unknown coverage for a fund without reports" do
    body = fetch
    expect(body.fetch("data")).to eq([])
    expect(portfolio(body)).to include("complete" => false, "known_value_usd" => nil, "total_value_usd" => nil,
      "position_count" => 0, "holding_row_count" => 0, "incomplete_report_ids" => [])
  end

  it "does not rank negative or nonfinite normalized values" do
    item = report
    holding = item.institutional_holdings.first
    [ -1, BigDecimal("NaN"), BigDecimal("Infinity") ].each do |value|
      holding.update!(value_usd: value)
      body = fetch
      expect(portfolio(body)).to include("complete" => false, "known_value_usd" => nil, "total_value_usd" => nil)
      expect(body.dig("data", 0, "position")).to include("value_usd" => nil, "rank" => nil, "weight_percent" => nil)
    end
  end

  it "withholds complete coverage for an amendment without a visible original" do
    report(amendment_type: "RESTATEMENT")
    body = fetch
    expect(body.fetch("data").length).to eq(1)
    expect(portfolio(body).fetch("complete")).to be(false)
    expect(body.dig("data", 0, "position", "rank")).to be_nil
  end

  it "keeps history gating and does not fetch external data" do
    report(period: Date.new(2024, 12, 31))
    get holdings_api_v1_fund_path(fund.cik), params: { period: "2024-12-31" }
    expect(response).to have_http_status(:payment_required)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
