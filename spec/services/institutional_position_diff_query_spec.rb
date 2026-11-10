# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstitutionalPositionDiffQuery do
  it "computes new, add, trim and exit changes in SQL" do
    filer = create(:institutional_filer)
    first_period = Date.new(2025, 12, 31)
    second_period = Date.new(2026, 3, 31)
    first = create_report(filer, first_period, Time.utc(2026, 2, 14))
    second = create_report(filer, second_period, Time.utc(2026, 5, 15))

    create(:institutional_holding, institutional_report: first, row_seq: 1, cusip: "037833100",
           shares: 100, value_usd: 10_000, name_of_issuer: "APPLE INC")
    create(:institutional_holding, institutional_report: first, row_seq: 2, cusip: "594918104",
           shares: 100, value_usd: 20_000, name_of_issuer: "MICROSOFT CORP")
    create(:institutional_holding, institutional_report: first, row_seq: 3, cusip: "02079K305",
           shares: 100, value_usd: 30_000, name_of_issuer: "ALPHABET INC")
    create(:institutional_holding, institutional_report: second, row_seq: 1, cusip: "037833100",
           shares: 150, value_usd: 15_000, name_of_issuer: "APPLE INC")
    create(:institutional_holding, institutional_report: second, row_seq: 2, cusip: "02079K305",
           shares: 50, value_usd: 15_000, name_of_issuer: "ALPHABET INC")
    create(:institutional_holding, institutional_report: second, row_seq: 3, cusip: "023135106",
           shares: 25, value_usd: 5_000, name_of_issuer: "AMAZON.COM INC")

    rows = described_class.new(institutional_filer_id: filer.id, period_of_report: second_period).call
    changes = rows.index_by { |row| [ row["cusip"], row["change_type"] ] }

    expect(changes.keys).to contain_exactly(
      [ "037833100", "add" ], [ "594918104", "exit" ],
      [ "02079K305", "trim" ], [ "023135106", "new" ]
    )
    expect(changes.fetch([ "037833100", "add" ])).to include("shares_delta" => 50.to_d)
    expect(changes.fetch([ "594918104", "exit" ])).to include("shares_delta" => -100.to_d)
  end

  it "aggregates repeated CUSIP rows by put/call and share type" do
    filer = create(:institutional_filer)
    first = create_report(filer, Date.new(2025, 12, 31), Time.utc(2026, 2, 14))
    second = create_report(filer, Date.new(2026, 3, 31), Time.utc(2026, 5, 15))
    create(:institutional_holding, institutional_report: first, row_seq: 1, cusip: "037833100", shares: 100)
    create(:institutional_holding, institutional_report: second, row_seq: 1, cusip: "037833100", shares: 60,
           investment_discretion: "SOLE")
    create(:institutional_holding, institutional_report: second, row_seq: 2, cusip: "037833100", shares: 60,
           investment_discretion: "SHARED", value_usd: nil, suspect: true)

    row = described_class.new(institutional_filer_id: filer.id, period_of_report: second.period_of_report)
      .call.find { |result| result["cusip"] == "037833100" }

    expect(row).to include("change_type" => "add", "shares_before" => 100.to_d, "shares_after" => 120.to_d,
                           "value_usd_after" => nil, "value_usd_delta" => nil, "current_suspect" => true)
  end

  private

  def create_report(filer, period, filed_at)
    create(
      :institutional_report,
      institutional_filer: filer,
      period_of_report: period,
      filed_at:,
      filing: create(:filing, cik: filer.cik, form_type: "13F-HR", period_of_report: period, filed_at:)
    )
  end
end
