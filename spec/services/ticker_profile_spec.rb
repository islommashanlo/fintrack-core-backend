# frozen_string_literal: true

require "rails_helper"

RSpec.describe TickerProfile do
  let(:as_of) { Time.utc(2026, 10, 2, 12, 0) }

  it "returns issuer activity from the ticker's parsed Form 4 filings" do
    filing = create(:filing, filed_at: as_of - 1.day, issuer_cik: "0000000123",
                             issuer_name: "Acme Corp", issuer_ticker: "ACME")
    create(:insider_transaction, filing:, insider_cik: "0000000456", insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 500, price: 25)

    profile = described_class.new(ticker: "acme", as_of:)

    expect(profile.issuer).to include("issuer_name" => "Acme Corp", "issuer_ticker" => "ACME")
    expect(profile.summary).to include("purchase_count" => 1, "insider_count" => 1,
                                       "purchase_value" => BigDecimal("12500"))
    expect(profile.transactions.first).to include("insider_name" => "Jane Doe", "transaction_code" => "P")
  end

  it "shows mapped institutional holdings without guessing unmapped CUSIPs" do
    institution = create(:institutional_filer, name: "Acme Capital")
    report = create(:institutional_report, institutional_filer: institution)
    create(:institutional_holding, institutional_report: report, cusip: "037833100",
                                   name_of_issuer: "ACME CORP", value_usd: 50_000)
    security = Security.create!(figi: "BBG000000001", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    holdings = described_class.new(ticker: "ACME", as_of: as_of).institutional_holdings

    expect(holdings).to include(
      include("institution_name" => "Acme Capital", "cusip" => "037833100", "value_usd" => BigDecimal("50000"))
    )
  end

  it "shows mapped institutional ownership changes for the latest quarter" do
    institution = create(:institutional_filer, name: "Acme Capital")
    period = Date.new(2026, 6, 30)
    report = create(:institutional_report, institutional_filer: institution, period_of_report: period,
                                        filed_at: Time.utc(2026, 8, 14))
    PositionDiff.create!(institutional_filer: institution, institutional_report: report,
                         period_of_report: period, cusip: "037833100", put_call: "C", share_type: "SH",
                         change_type: "add", shares_delta: 100, value_usd_delta: 50_000,
                         name_of_issuer: "ACME CORP", title_of_class: "COM", calculated_at: Time.current)
    security = Security.create!(figi: "BBG000000002", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    changes = described_class.new(ticker: "ACME", as_of: as_of).institutional_changes

    expect(changes).to include(
      include("institution_name" => "Acme Capital", "change_type" => "add",
              "shares_delta" => BigDecimal("100"), "value_usd_delta" => BigDecimal("50000"))
    )
  end

  it "returns mapped institutional ownership across the selected quarters" do
    institution = create(:institutional_filer, name: "Acme Capital")
    current_period = Date.new(2026, 6, 30)
    prior_period = Date.new(2026, 3, 31)
    current_report = create(:institutional_report, institutional_filer: institution,
                            period_of_report: current_period, filed_at: Time.utc(2026, 8, 14))
    current_addition = create(:institutional_report, institutional_filer: institution,
                              period_of_report: current_period, filed_at: Time.utc(2026, 8, 15),
                              submission_type: "13F-HR/A", amendment_type: "NEW HOLDINGS")
    prior_report = create(:institutional_report, institutional_filer: institution,
                          period_of_report: prior_period, filed_at: Time.utc(2026, 5, 15))
    create(:institutional_holding, institutional_report: current_report, cusip: "037833100",
                                   shares: 150, value_usd: 30_000)
    create(:institutional_holding, institutional_report: current_addition, cusip: "037833100",
                                   shares: 25, value_usd: 5_000)
    create(:institutional_holding, institutional_report: prior_report, cusip: "037833100",
                                   shares: 100, value_usd: 20_000)
    security = Security.create!(figi: "BBG000000003", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    history = described_class.new(ticker: "ACME", as_of: as_of).institutional_history(periods: 2)

    expect(history.map { |row| row["period_of_report"] }).to eq([ current_period, prior_period ])
    expect(history.first).to include("institution_name" => "Acme Capital", "shares" => BigDecimal("175"),
                                     "value_usd" => BigDecimal("35000"))
  end

  it "does not include holdings filed after the point-in-time cutoff" do
    institution = create(:institutional_filer, name: "Acme Capital")
    report = create(:institutional_report, institutional_filer: institution,
                    period_of_report: Date.new(2026, 6, 30), filed_at: Time.utc(2026, 8, 14))
    create(:institutional_holding, institutional_report: report, cusip: "037833100", shares: 100, value_usd: 20_000)
    security = Security.create!(figi: "BBG000000004", ticker: "ACME", name: "Acme Corp", source: "openfigi")
    CusipSecurityMapping.create!(cusip: "037833100", security:, source: "openfigi", result_seq: 0,
                                 status: "mapped", first_seen_at: Time.current, last_checked_at: Time.current)

    history = described_class.new(ticker: "ACME", as_of: Time.utc(2026, 8, 1)).institutional_history

    expect(history).to be_empty
  end
end
