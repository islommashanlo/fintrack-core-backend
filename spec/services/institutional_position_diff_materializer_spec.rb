# frozen_string_literal: true

require "rails_helper"

RSpec.describe InstitutionalPositionDiffMaterializer do
  it "materializes SQL rows and re-running leaves derived counts unchanged" do
    filer = create(:institutional_filer)
    first_period = Date.new(2025, 12, 31)
    second_period = Date.new(2026, 3, 31)
    first = create_report(filer, first_period, Time.utc(2026, 2, 14))
    second = create_report(filer, second_period, Time.utc(2026, 5, 15))
    create(:institutional_holding, institutional_report: first, row_seq: 1, cusip: "037833100", shares: 100)
    create(:institutional_holding, institutional_report: second, row_seq: 1, cusip: "037833100", shares: 150)

    expect do
      described_class.call(institutional_filer_id: filer.id, period_of_report: second_period)
    end.to change(PositionDiff, :count).by(1)

    described_class.call(institutional_filer_id: filer.id, period_of_report: second_period)

    expect(PositionDiff.count).to eq(1)
    expect(PositionDiff.sole).to have_attributes(change_type: "add", shares_delta: 50.to_d)
  end

  it "links an exited position to the current quarter's report" do
    filer = create(:institutional_filer)
    first = create_report(filer, Date.new(2025, 12, 31), Time.utc(2026, 2, 14))
    second = create_report(filer, Date.new(2026, 3, 31), Time.utc(2026, 5, 15))
    create(:institutional_holding, institutional_report: first)

    described_class.call(institutional_filer_id: filer.id, period_of_report: second.period_of_report)

    expect(PositionDiff.sole).to have_attributes(change_type: "exit", institutional_report: second,
                                                prior_institutional_report: first)
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
