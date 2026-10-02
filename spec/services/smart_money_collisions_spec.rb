# frozen_string_literal: true

require "rails_helper"

RSpec.describe SmartMoneyCollisions do
  let(:as_of) { Time.utc(2026, 10, 2, 12, 0) }

  it "matches insider purchases to mapped institutional additions by filing time" do
    institution = create(:institutional_filer, name: "Acme Capital")
    report = create(:institutional_report, institutional_filer: institution,
                    period_of_report: Date.new(2026, 6, 30), filed_at: Time.utc(2026, 8, 14))
    PositionDiff.create!(institutional_filer: institution, institutional_report: report,
                         period_of_report: report.period_of_report, cusip: "037833100", put_call: "C",
                         share_type: "SH", change_type: "add", shares_delta: 100, value_usd_delta: 50_000,
                         name_of_issuer: "ACME CORP", title_of_class: "COM", calculated_at: Time.current)
    filing = create(:filing, filed_at: Time.utc(2026, 8, 20), issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing:, insider_cik: "0000000456", insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 100, price: 25)
    security = Security.create!(figi: "BBG000000005", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    rows = described_class.new(as_of:).matches

    expect(rows).to include(
      include("ticker" => "ACME", "issuer_name" => "Acme Corp", "insiders" => 1,
              "institutions" => 1, "insider_filings" => 1, "institutional_reports" => 1)
    )
    expect(described_class.new(as_of:).matches(ticker: "BETA")).to be_empty
  end

  it "excludes matches outside the filing-time window and future filings" do
    institution = create(:institutional_filer)
    report = create(:institutional_report, institutional_filer: institution,
                    period_of_report: Date.new(2026, 6, 30), filed_at: Time.utc(2026, 8, 14))
    PositionDiff.create!(institutional_filer: institution, institutional_report: report,
                         period_of_report: report.period_of_report, cusip: "037833100", put_call: "C",
                         share_type: "SH", change_type: "add", shares_delta: 100, value_usd_delta: 50_000,
                         name_of_issuer: "ACME CORP", title_of_class: "COM", calculated_at: Time.current)
    old_filing = create(:filing, filed_at: Time.utc(2026, 1, 1), issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing: old_filing, insider_cik: "0000000456", transaction_code: "P")
    future_filing = create(:filing, filed_at: as_of + 1.hour, issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing: future_filing, insider_cik: "0000000457", transaction_code: "P")
    security = Security.create!(figi: "BBG000000006", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    expect(described_class.new(as_of:).matches).to be_empty
  end
end
