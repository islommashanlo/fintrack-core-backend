# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstitutionalProfile do
  it "returns effective holdings for the institution's latest parsed period" do
    institution = create(:institutional_filer)
    report = create(:institutional_report, institutional_filer: institution)
    create(:institutional_holding, institutional_report: report, name_of_issuer: "APPLE INC",
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
end
