# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Institution profiles" do
  let!(:institution) { create(:institutional_filer, name: "Acme Capital") }
  let(:profile) { instance_double(InstitutionalProfile) }

  before do
    create(:institutional_report, institutional_filer: institution)
    allow(InstitutionalProfile).to receive(:new).with(institutional_filer: institution).and_return(profile)
    allow(profile).to receive(:latest_report).and_return(InstitutionalReport.last)
    allow(profile).to receive(:top_holdings).and_return([
      { "name_of_issuer" => "APPLE INC", "title_of_class" => "COM", "cusip" => "037833100",
        "shares" => BigDecimal("100"), "value_usd" => BigDecimal("25000"), "put_call" => "", "share_type" => "SH",
        "suspect" => false }
    ])
    allow(profile).to receive(:position_changes).and_return([])
    allow(profile).to receive(:report_history).and_return([])
  end

  it "shows the latest report and largest positions" do
    get institution_path(institution.cik)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Acme Capital", "APPLE INC", "Largest reported positions",
                                     "13F reports", "13F filings show long positions")
  end
end
