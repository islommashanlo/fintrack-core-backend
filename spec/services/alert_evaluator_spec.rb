# frozen_string_literal: true

require "rails_helper"

RSpec.describe AlertEvaluator do
  it "creates one delivery per matching insider and ticker rule" do
    user = create(:user)
    create(:follow, user:, target_type: "Insider", target_key: "0000000456")
    create(:follow, user:, target_type: "Ticker", target_key: "ACME")
    filing = create(:filing, issuer_ticker: "ACME", issuer_name: "Acme Corp")
    create(:insider_transaction, filing:, insider_cik: "0000000456")

    expect do
      described_class.call(filing)
    end.to change(AlertDelivery, :count).by(2)

    expect(SendAlertJob).to have_been_enqueued.exactly(2).times
    expect { described_class.call(filing) }.not_to change(AlertDelivery, :count)
  end

  it "matches an institution's parsed 13F filing" do
    user = create(:user)
    institution = create(:institutional_filer, cik: "0000000789")
    create(:follow, user:, target_type: "InstitutionalFiler", target_key: institution.cik)
    filing = create(:filing, form_type: "13F-HR", cik: institution.cik)
    create(:institutional_report, filing:, institutional_filer: institution)

    expect do
      described_class.call(filing)
    end.to change(AlertDelivery, :count).by(1)
  end

  it "ignores inactive rules and unrelated filing types" do
    user = create(:user)
    follow = create(:follow, user:, target_type: "Ticker", target_key: "ACME")
    follow.alert_rule.update!(active: false)
    filing = create(:filing, form_type: "4", issuer_ticker: "ACME")

    expect { described_class.call(filing) }.not_to change(AlertDelivery, :count)

    unknown = create(:filing, form_type: "8-K", issuer_ticker: "ACME")
    expect { described_class.call(unknown) }.not_to change(AlertDelivery, :count)
  end
end
