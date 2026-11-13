# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fund screener reported labels" do
  include OpenapiResponses
  include ApiAccounts
  include InstitutionalReadHelpers
  around { |example| travel_to(Time.utc(2026, 11, 13, 12)) { example.run } }
  let(:fund) { create(:institutional_filer) }

  def report(rows: 1, **attributes)
    item = create_13f(fund:, period: Date.new(2026, 9, 30), filed_at: 2.days.ago, **attributes)
    rows.times { create(:institutional_holding, institutional_report: item, value_reported: 100, value_usd: 100) }
    item.update!(table_entry_total: rows, table_value_total: rows * 100)
    item
  end

  def condition(field, value, operator = "eq")
    { field:, operator:, value: }
  end

  def screen(filters: [], **options)
    post api_v1_screener_run_path, params: { entity: "funds", filters:, **options }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/screener/run", method: :post)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    response.parsed_body
  end

  it "matches contributing cover labels without trimming the complete portfolio" do
    original = report
    addition = report(amendment_type: "NEW HOLDINGS", report_type: "13F COMBINATION REPORT", filed_at: 1.day.ago)
    result = screen(filters: [ condition("coverage", "complete"), condition("report_type", "holdings"),
      condition("report_type", "combination"), condition("holding_row_count", 2) ]).fetch("data").sole
    expect(result.fetch("report_types")).to match_array([ "13F HOLDINGS REPORT", "13F COMBINATION REPORT" ])
    expect(result.fetch("report_type_sources").pluck("accession")).to match_array([ original.filing.accession_no, addition.filing.accession_no ])
    expect(result.fetch("metrics")).to include("holding_row_count" => 2, "portfolio_value_usd" => "200.0")
    expect(result.fetch("coverage")).to eq("complete")
  end

  it "excludes superseded covers and noncontributing notices from membership and evidence" do
    report(report_type: "13F COMBINATION REPORT", filed_at: 3.days.ago)
    replacement = report(amendment_type: "RESTATEMENT")
    notice = report(submission_type: "13F-NT", report_type: "13F NOTICE", filed_at: 1.day.ago, rows: 0)
    result = screen(filters: [ condition("report_type", "holdings") ]).fetch("data").sole
    expect(result.fetch("accession")).to eq(notice.filing.accession_no)
    expect(result.fetch("report_type_sources").pluck("accession")).to eq([ replacement.filing.accession_no ])
    %w[combination notice].each do |token|
      expect(screen(filters: [ condition("report_type", token) ]).fetch("data")).to eq([])
    end
  end

  it "uses the observed notice cover when holdings are absent and distinguishes empty holdings" do
    report(submission_type: "13F-NT", report_type: "13F NOTICE", rows: 0)
    result = screen(filters: [ condition("coverage", "no_effective_holdings"), condition("report_type", "notice") ]).fetch("data").sole
    expect(result).to include("report_types" => [ "13F NOTICE" ], "source_filing_count" => 0)
    expect(result.fetch("report_type_sources").sole.fetch("report_type")).to eq("13F NOTICE")
    report(rows: 0, filed_at: 1.day.ago)
    expect(screen(filters: [ condition("coverage", "complete") ]).fetch("data").sole.fetch("metrics"))
      .to include("holding_row_count" => 0, "portfolio_value_usd" => "0.0")
  end

  it "preserves unfamiliar stored labels without inventing a request token" do
    report(report_type: "AS REPORTED UNKNOWN")
    result = screen.fetch("data").sole
    expect(result.fetch("report_types")).to eq([ "AS REPORTED UNKNOWN" ])
    expect(result.fetch("report_type_sources").sole.fetch("report_type")).to eq("AS REPORTED UNKNOWN")
    expect(screen(filters: [ condition("report_type", "holdings") ]).fetch("data")).to eq([])
  end

  it "withholds restricted labels even from negative membership conditions" do
    report(period: Date.new(2025, 9, 30))
    result = screen(filters: [ condition("coverage", "history_restricted") ]).fetch("data").sole
    expect(result).to include("report_types" => nil, "report_type_sources" => [], "coverage" => "history_restricted")
    [ condition("report_type", "holdings"), condition("report_type", "notice", "not_eq"),
      condition("report_type", %w[holdings combination], "in") ].each do |filter|
      expect(screen(filters: [ filter ]).fetch("data")).to eq([])
    end
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "reveals historical labels only during verified Pro access" do
    report(period: Date.new(2025, 9, 30))
    with_billing_config do
      user = create(:user, password: "password123")
      bind_billing_customer(user)
      apply_billing_event
      api_login(user)
      expect(screen(filters: [ condition("report_type", "holdings") ]).fetch("data").sole.fetch("coverage")).to eq("complete")
      apply_billing_event(id: "evt_labels_canceled", snapshot: billing_snapshot(status: "canceled"), type: "customer.subscription.deleted")
      expect(screen(filters: [ condition("report_type", "notice", "not_eq") ]).fetch("data")).to eq([])
    end
  end

  it "keeps label pagination bounded to its source snapshot and rejects changed conditions" do
    report
    other = create(:institutional_filer)
    item = create_13f(fund: other, period: Date.new(2026, 9, 30))
    create(:institutional_holding, institutional_report: item, value_reported: 100, value_usd: 100)
    item.update!(table_entry_total: 1, table_value_total: 100)
    filters = [ condition("report_type", "holdings") ]
    first = screen(filters:, sort: "coverage", limit: 1)
    cursor = first.dig("meta", "next_cursor")
    expect(cursor).to be_present
    report(amendment_type: "RESTATEMENT", report_type: "13F COMBINATION REPORT", filed_at: Time.current)
    second = screen(filters:, sort: "coverage", limit: 1, cursor:)
    expect((first.fetch("data") + second.fetch("data")).pluck("cik")).to match_array([ fund.cik, other.cik ])
    post api_v1_screener_run_path, params: { entity: "funds", filters: [ condition("report_type", "combination") ],
      sort: "coverage", limit: 1, cursor: }, headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
  end
end
