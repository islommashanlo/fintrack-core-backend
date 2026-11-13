# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 funds" do
  include OpenapiResponses
  include InstitutionalReadHelpers

  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  it "lists and searches funds with stable name ties, literal wildcards and scoped cursors" do
    first = create(:institutional_filer, name: "Example Capital")
    second = create(:institutional_filer, name: "Example Capital")
    create(:institutional_filer, name: "Other Fund")
    get api_v1_funds_path, params: { q: "example", limit: 1 }
    expect(data).to eq([ { "cik" => first.cik, "name" => first.name, "reported_portfolio" => nil, "portfolio_unavailable_reason" => "no_report" } ])
    cursor = meta.fetch("next_cursor")
    create(:institutional_filer, name: first.name)

    get api_v1_funds_path, params: { q: "example", limit: 1, cursor: }
    expect(data.pluck("cik")).to eq([ second.cik ])
    expect(meta).to include("total_count" => 2, "has_more" => false)

    get api_v1_funds_path, params: { q: "other", cursor: }
    expect(response).to have_http_status(:bad_request)
    get api_v1_funds_path, params: { q: "%" }
    expect(data).to eq([])
  end

  it "returns the latest known report with cover metadata and freshness" do
    fund = create(:institutional_filer)
    latest = create_13f(fund:, table_entry_total: 12, table_value_total: 1500,
                        other_included_managers_count: 2, suspect: true, suspect_reason: "entry_count_mismatch")
    create_13f(fund:, period: Date.new(2026, 9, 30), filed_at: 1.day.from_now)

    get api_v1_fund_path(fund.cik)
    expect_documented_response(path: "/funds/{cik}")

    expect(data).to include("cik" => fund.cik, "name" => fund.name)
    expect(data.fetch("latest_report")).to include(
      "accession" => latest.filing.accession_no, "sec_url" => latest.filing.sec_url,
      "period_of_report" => "2026-06-30", "table_entry_total" => 12,
      "table_value_total" => "1500.0", "other_manager_count" => 2,
      "value_unit" => "whole_dollars", "suspect" => true,
      "filed_at" => "2026-08-14T00:00:00.000Z", "data_age_days" => 88
    )
  end

  it "returns a fund with no reports and a JSON 404 for unknown funds" do
    fund = create(:institutional_filer)
    get api_v1_fund_path(fund.cik)
    expect_documented_response(path: "/funds/{cik}")
    expect(data.fetch("latest_report")).to be_nil

    get api_v1_fund_path("0000000001")
    expect_documented_response(path: "/funds/{cik}")
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("NOT_FOUND")
  end

  it "resolves restatements and additions, retains same-CUSIP lines, and preserves raw values" do
    fund = create(:institutional_filer)
    original = create_13f(fund:)
    create(:institutional_holding, institutional_report: original, shares: 999)
    restatement = create_13f(fund:, filed_at: Time.utc(2026, 8, 15), amendment_type: "RESTATEMENT")
    first = create(:institutional_holding, institutional_report: restatement, shares: 20,
                    value_reported: 25, value_unit: "thousands", value_usd: 25_000)
    second = create(:institutional_holding, institutional_report: restatement, put_call: "PUT", shares: 5)
    addition = create_13f(fund:, filed_at: restatement.filed_at, amendment_type: "NEW HOLDINGS")
    added = create(:institutional_holding, institutional_report: addition, shares: 30, suspect: true)
    future = create_13f(fund:, filed_at: 1.day.from_now, amendment_type: "RESTATEMENT")
    create(:institutional_holding, institutional_report: future)

    get holdings_api_v1_fund_path(fund.cik)
    expect_documented_response(path: "/funds/{cik}/holdings")

    expect(data.pluck("id")).to contain_exactly(first.id, second.id, added.id)
    expect(data.find { |row| row["id"] == first.id }).to include(
      "accession" => restatement.filing.accession_no, "value_reported" => "25.0", "value_unit" => "thousands",
      "value_usd" => "25000.0", "shares" => "20.0", "fund" => { "cik" => fund.cik, "name" => fund.name }
    )
    expect(InstitutionalHolding.where(id: [ first.id, second.id, added.id ]).count).to eq(3)
  end

  it "does not treat notices or unresolved additions as holdings bases" do
    fund = create(:institutional_filer)
    create_13f(fund:)
    notice = create_13f(fund:, period: Date.new(2026, 9, 30), submission_type: "13F-NT", report_type: "13F NOTICE")
    create(:institutional_holding, institutional_report: notice)

    get holdings_api_v1_fund_path(fund.cik)
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(data).to eq([])

    orphan = create_13f(fund:, period: Date.new(2025, 12, 31), amendment_type: "NEW HOLDINGS")
    create(:institutional_holding, institutional_report: orphan)
    get holdings_api_v1_fund_path(fund.cik), params: { period: "2025-12-31" }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(data).to eq([])
  end

  it "filters holdings by period and security attributes" do
    fund = create(:institutional_filer)
    old = create_13f(fund:, period: Date.new(2026, 3, 31))
    wanted = create(:institutional_holding, institutional_report: old, put_call: "CALL", share_type: "PRN")
    create(:institutional_holding, institutional_report: old, put_call: "PUT")
    current = create_13f(fund:)
    create(:institutional_holding, institutional_report: current, put_call: "CALL", share_type: "PRN")

    get holdings_api_v1_fund_path(fund.cik), params: { period: "2026-03-31", cusip: wanted.cusip, put_call: "CALL", share_type: "PRN" }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(data.pluck("id")).to eq([ wanted.id ])
  end

  it "paginates holdings through ties and nulls and ignores late restatements" do
    fund = create(:institutional_filer)
    report = create_13f(fund:)
    first = create(:institutional_holding, institutional_report: report, value_usd: nil)
    second = create(:institutional_holding, institutional_report: report, value_usd: nil)
    third = create(:institutional_holding, institutional_report: report, value_usd: 100)
    get holdings_api_v1_fund_path(fund.cik), params: { limit: 1 }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(data.pluck("id")).to eq([ third.id ])
    cursor = meta.fetch("next_cursor")
    replacement = create_13f(fund:, amendment_type: "RESTATEMENT", filed_at: Time.utc(2026, 8, 20))
    create(:institutional_holding, institutional_report: replacement)

    get holdings_api_v1_fund_path(fund.cik), params: { limit: 1, cursor: }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(data.pluck("id")).to eq([ second.id ])
    cursor = meta.fetch("next_cursor")
    get holdings_api_v1_fund_path(fund.cik), params: { limit: 1, cursor: }
    expect_documented_response(path: "/funds/{cik}/holdings")
    expect(data.pluck("id")).to eq([ first.id ])
    expect(meta).to include("total_count" => 3, "has_more" => false)
  end

  it "paginates report history with provenance and keeps superseded reports" do
    fund = create(:institutional_filer)
    original = create_13f(fund:)
    amendment = create_13f(fund:, filed_at: Time.utc(2026, 8, 15), amendment_type: "RESTATEMENT")
    failed = create_13f(fund:, status: "failed")
    create_13f(fund:, filed_at: 1.day.from_now)

    get history_api_v1_fund_path(fund.cik), params: { sort: "-filed_at", limit: 1 }
    expect(data.pluck("id")).to eq([ amendment.id ])
    cursor = meta.fetch("next_cursor")
    get history_api_v1_fund_path(fund.cik), params: { sort: "-filed_at", limit: 1, cursor: }
    expect(data.pluck("id")).to eq([ original.id ])
    expect(meta).to include("total_count" => 2, "has_more" => false)
    expect(data.pluck("id")).not_to include(failed.id)
  end

  it "rejects invalid filters, structured parameters and cross-resource cursors" do
    fund = create(:institutional_filer)
    report = create_13f(fund:)
    create_list(:institutional_holding, 2, institutional_report: report)
    get holdings_api_v1_fund_path(fund.cik), params: { limit: 1 }
    expect_documented_response(path: "/funds/{cik}/holdings")
    cursor = meta.fetch("next_cursor")
    get history_api_v1_fund_path(fund.cik), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    [ { period: "2026-09-29" }, { period: "2026-02-30" }, { cusip: "invalid" }, { put_call: "OTHER" },
      { share_type: "invalid" }, { sort: "price; SELECT 1" }, { limit: "101" }, { period: [] } ].each do |values|
      get holdings_api_v1_fund_path(fund.cik), params: values
      expect_documented_response(path: "/funds/{cik}/holdings")
      expect(response).to have_http_status(:bad_request), values.inspect
    end
  end

  it "computes current position changes from effective reports and links every contributing filing" do
    fund = create(:institutional_filer)
    prior = create_13f(fund:, period: Date.new(2026, 3, 31), filed_at: Time.utc(2026, 5, 15))
    current = create_13f(fund:)
    addition = create_13f(fund:, filed_at: Time.utc(2026, 8, 15), amendment_type: "NEW HOLDINGS")
    create(:institutional_holding, institutional_report: prior, cusip: "037833100", shares: 100, value_usd: 1000)
    create(:institutional_holding, institutional_report: current, cusip: "037833100", shares: 120, value_usd: 1200)
    create(:institutional_holding, institutional_report: addition, cusip: "037833100", shares: 10, value_usd: 100)
    create(:institutional_holding, institutional_report: prior, cusip: "594918104", shares: 50, value_usd: 500)
    create(:institutional_holding, institutional_report: current, cusip: "02079K305", shares: 30, value_usd: 300)
    create(:institutional_holding, institutional_report: prior, cusip: "023135106", shares: 100, value_usd: 1000)
    create(:institutional_holding, institutional_report: current, cusip: "023135106", shares: 50, value_usd: 500)
    future = create_13f(fund:, filed_at: 1.day.from_now, amendment_type: "RESTATEMENT")
    create(:institutional_holding, institutional_report: future, shares: 999)

    expect do
      get changes_api_v1_fund_path(fund.cik)
      expect_documented_response(path: "/funds/{cik}/changes")
    end.not_to change(PositionDiff, :count)

    expect(data.pluck("change_type")).to contain_exactly("added", "exited", "new", "reduced")
    added = data.find { |row| row["change_type"] == "added" }
    expect(added).to include("shares_before" => "100.0", "shares_after" => "130.0", "shares_delta" => "30.0",
                             "accession" => addition.filing.accession_no, "sec_url" => addition.filing.sec_url)
    expect(added.fetch("current_sources").pluck("accession")).to contain_exactly(current.filing.accession_no, addition.filing.accession_no)
    expect(added.fetch("prior_sources").pluck("accession")).to eq([ prior.filing.accession_no ])
    exited = data.find { |row| row["change_type"] == "exited" }
    expect(exited).to include("accession" => current.filing.accession_no, "shares_delta" => "-50.0")

    get changes_api_v1_fund_path(fund.cik), params: { change_type: "added", limit: 1 }
    expect_documented_response(path: "/funds/{cik}/changes")
    expect(data.pluck("cusip")).to eq([ "037833100" ])
    expect(meta.fetch("total_count")).to eq(1)
  end

  it "pages through position changes without relying on a materialization job" do
    fund = create(:institutional_filer)
    report = create_13f(fund:)
    create(:institutional_holding, institutional_report: report, cusip: "037833100", value_usd: 100)
    create(:institutional_holding, institutional_report: report, cusip: "594918104", value_usd: 100)

    get changes_api_v1_fund_path(fund.cik), params: { limit: 1 }
    expect_documented_response(path: "/funds/{cik}/changes")
    first = data.first.fetch("cusip")
    cursor = meta.fetch("next_cursor")
    get changes_api_v1_fund_path(fund.cik), params: { limit: 1, cursor: }
    expect_documented_response(path: "/funds/{cik}/changes")
    expect(data.first.fetch("cusip")).not_to eq(first)
    expect(meta).to include("total_count" => 2, "has_more" => false)
    get changes_api_v1_fund_path(fund.cik), params: { change_type: "invalid" }
    expect_documented_response(path: "/funds/{cik}/changes")
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects modified and expired shared cursors" do
    create_list(:institutional_filer, 2)
    get api_v1_funds_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    get api_v1_funds_path, params: { cursor: "#{cursor}x" }
    expect(response).to have_http_status(:bad_request)
    travel 25.hours
    get api_v1_funds_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end
end
