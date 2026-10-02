# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstitutionalFlow do
  let(:as_of) { Time.utc(2026, 10, 2, 12, 0) }

  it "aggregates the latest available quarter by security" do
    apple_filer = create(:institutional_filer, name: "Apple Capital")
    beta_filer = create(:institutional_filer, name: "Beta Capital")
    period = Date.new(2026, 6, 30)
    apple_report = report_for(apple_filer, period, Time.utc(2026, 8, 14))
    beta_report = report_for(beta_filer, period, Time.utc(2026, 8, 15))
    create_diff(apple_filer, apple_report, period, cusip: "037833100", name: "APPLE INC", value: 100_000)
    create_diff(beta_filer, beta_report, period, cusip: "037833100", name: "APPLE INC", value: -25_000,
                change_type: "trim")
    create_diff(apple_filer, apple_report, period, cusip: "594918104", name: "MICROSOFT CORP", value: -80_000,
                change_type: "exit")
    old_report = report_for(apple_filer, Date.new(2026, 3, 31), Time.utc(2026, 5, 15))
    create_diff(apple_filer, old_report, Date.new(2026, 3, 31), cusip: "02079K305", name: "ALPHABET INC", value: 999_000)

    rows = described_class.new(as_of:).top_moves

    expect(rows.map { |row| row["cusip"] }).to eq(%w[594918104 037833100])
    expect(rows.first).to include("name_of_issuer" => "MICROSOFT CORP", "net_value_usd_delta" => -80_000)
    expect(rows.last).to include("name_of_issuer" => "APPLE INC", "net_value_usd_delta" => 75_000,
                                 "institutions" => 2, "moves" => 2)
  end

  it "leaves a security out when every value delta is suspect" do
    filer = create(:institutional_filer)
    report = report_for(filer, Date.new(2026, 6, 30), Time.utc(2026, 8, 14))
    create_diff(filer, report, Date.new(2026, 6, 30), cusip: "037833100", name: "APPLE INC", value: 100_000,
                current_suspect: true)

    expect(described_class.new(as_of:).top_moves).to be_empty
  end

  private

  def report_for(filer, period, filed_at)
    create(:institutional_report, institutional_filer: filer, period_of_report: period, filed_at:,
           filing: create(:filing, cik: filer.cik, form_type: "13F-HR", period_of_report: period, filed_at:))
  end

  def create_diff(filer, report, period, cusip:, name:, value:, change_type: "add", current_suspect: false)
    PositionDiff.create!(institutional_filer: filer, institutional_report: report,
                         period_of_report: period, cusip:, put_call: "C", share_type: "SH", change_type:,
                         shares_delta: 100, value_usd_delta: value, name_of_issuer: name, title_of_class: "COM",
                         current_suspect:, prior_suspect: false, calculated_at: Time.current)
  end
end
