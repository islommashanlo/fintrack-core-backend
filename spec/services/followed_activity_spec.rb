# frozen_string_literal: true

require "rails_helper"

RSpec.describe FollowedActivity do
  let(:as_of) { Time.utc(2026, 10, 10, 12, 0) }

  it "combines followed Form 4 and 13F activity in filing-time order" do
    user = create(:user)
    insider_filing = create(:filing, filed_at: as_of - 2.days, issuer_ticker: "ACME", issuer_name: "Acme Corp")
    create(:insider_transaction, filing: insider_filing, insider_cik: "0000000456", insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 100, price: 10)

    institution = create(:institutional_filer, cik: "0000000789", name: "Acme Capital")
    create(:institutional_report, institutional_filer: institution, filed_at: as_of - 1.day,
                                 submission_type: "13F-HR", report_type: "13F HOLDINGS REPORT")

    create(:follow, user:, target_type: "Insider", target_key: "0000000456")
    create(:follow, user:, target_type: "InstitutionalFiler", target_key: institution.cik)

    rows = described_class.new(user:, as_of:).recent

    expect(rows.map { |row| row["activity_source"] }).to eq(%w[13F Form\ 4])
    expect(rows.first).to include("label" => "Acme Capital", "activity_kind" => "13F-HR", "filing_cik" => institution.cik)
    expect(rows.last).to include("label" => "Jane Doe", "activity_kind" => "P", "filing_cik" => insider_filing.cik,
                                 "value" => 1000)
  end

  it "includes 10b5-1 status and dates for followed Form 4 activity" do
    user = create(:user)
    filing = create(:filing, filed_at: as_of - 1.day, issuer_ticker: "ACME", issuer_name: "Acme Corp",
                             aff10b5_one: true,
                             footnotes: { "F1" => "These shares were purchased pursuant to a Rule 10b5-1 trading plan adopted on May 19, 2026." })
    create(:insider_transaction, filing:, insider_cik: "0000000456", insider_name: "Jane Doe",
                                 transaction_code: "P", shares: 100, price: 10, footnote_ids: %w[F1])
    create(:follow, user:, target_type: "Insider", target_key: "0000000456")

    expect(described_class.new(user:, as_of:).recent.first).to include(
      "plan_status" => "10b5-1 plan disclosed",
      "plan_adoption_date" => Date.new(2026, 5, 19)
    )
  end

  it "only returns activity for the requested user and filing window" do
    user = create(:user)
    other_user = create(:user, email_address: "other@example.com")
    filing = create(:filing, filed_at: as_of - 45.days, issuer_ticker: "OLD")
    create(:insider_transaction, filing:, insider_cik: "0000000456")
    create(:follow, user: other_user, target_type: "Ticker", target_key: "ACME")
    create(:follow, user:, target_type: "Ticker", target_key: "OLD")

    expect(described_class.new(user:, as_of:).recent).to be_empty
  end
end
