# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstitutionalProfile do
  it "returns effective holdings for the institution's latest parsed period" do
    institution = create(:institutional_filer)
    report = create(:institutional_report, institutional_filer: institution)
    create(:institutional_holding, institutional_report: report, row_seq: 1, name_of_issuer: "APPLE INC",
                                   cusip: "037833100", shares: 100, value_usd: 25_000)
    create(:institutional_holding, institutional_report: report, row_seq: 2, name_of_issuer: "MICROSOFT CORP",
                                   cusip: "594918104", shares: 50, value_usd: 15_000)

    profile = described_class.new(institutional_filer: institution)

    expect(profile.latest_report).to eq(report)
    expect(profile.top_holdings(limit: 1)).to include(
      include("name_of_issuer" => "APPLE INC", "cusip" => "037833100", "value_usd" => BigDecimal("25000"))
    )
  end

  it "orders materialized changes by the size of the value move" do
    institution = create(:institutional_filer)
    report = create(:institutional_report, institutional_filer: institution)
    PositionDiff.create!(institutional_filer: institution, institutional_report: report,
                         period_of_report: report.period_of_report, cusip: "037833100", share_type: "SH",
                         put_call: "C", change_type: "add", shares_delta: 100, value_usd_delta: 50_000,
                         name_of_issuer: "APPLE INC", title_of_class: "COM", calculated_at: Time.current)
    PositionDiff.create!(institutional_filer: institution, institutional_report: report,
                         period_of_report: report.period_of_report, cusip: "594918104", share_type: "SH",
                         put_call: "C", change_type: "trim", shares_delta: -50, value_usd_delta: -2_000,
                         name_of_issuer: "MICROSOFT CORP", title_of_class: "COM", calculated_at: Time.current)

    changes = described_class.new(institutional_filer: institution).position_changes

    expect(changes.map { |change| change["cusip"] }).to eq(%w[037833100 594918104])
  end

  it "returns parsed reports in filing-time order, including amendments" do
    institution = create(:institutional_filer)
    original = create(:institutional_report, institutional_filer: institution,
                      period_of_report: Date.new(2025, 12, 31), filed_at: Time.utc(2026, 2, 14, 20, 0),
                      submission_type: "13F-HR", amendment_type: nil)
    amendment = create(:institutional_report, institutional_filer: institution,
                       period_of_report: original.period_of_report, filed_at: Time.utc(2026, 2, 16, 20, 0),
                       submission_type: "13F-HR/A", amendment_type: "RESTATEMENT")
    newer = create(:institutional_report, institutional_filer: institution,
                   period_of_report: Date.new(2026, 3, 31), filed_at: Time.utc(2026, 5, 15, 20, 0))

    history = described_class.new(institutional_filer: institution).report_history

    expect(history.map { |report| report["id"] }).to eq([ newer.id, amendment.id, original.id ])
    expect(history[1]).to include("amendment_type" => "RESTATEMENT", "accession_no" => amendment.filing.accession_no)
  end

  it "excludes reports filed after the point-in-time cutoff" do
    institution = create(:institutional_filer)
    visible = create(:institutional_report, institutional_filer: institution,
                     filed_at: Time.utc(2026, 5, 15, 20, 0))
    create(:institutional_report, institutional_filer: institution,
           filed_at: Time.utc(2026, 8, 15, 20, 0), period_of_report: Date.new(2026, 6, 30))

    history = described_class.new(institutional_filer: institution,
                                  as_of: Time.utc(2026, 6, 1, 0, 0)).report_history

    expect(history.map { |report| report["id"] }).to eq([ visible.id ])
  end
end
