# frozen_string_literal: true

require "rails_helper"

RSpec.describe "institutional 13F schema" do
  it "creates the four new tables and leaves the existing filings contract usable" do
    connection = ActiveRecord::Base.connection

    expect(connection.data_source_exists?("institutional_filers")).to be(true)
    expect(connection.data_source_exists?("institutional_reports")).to be(true)
    expect(connection.data_source_exists?("institutional_report_managers")).to be(true)
    expect(connection.data_source_exists?("institutional_holdings")).to be(true)
    expect(Filing.column_names).to include("accession_no", "filed_at", "period_of_report", "parse_status")
  end

  it "creates separate enrichment and derived-diff tables" do
    connection = ActiveRecord::Base.connection

    expect(connection.data_source_exists?("securities")).to be(true)
    expect(connection.data_source_exists?("cusip_security_mappings")).to be(true)
    expect(connection.data_source_exists?("position_diffs")).to be(true)
    expect(PositionDiff::NATURAL_KEY).to eq(
      %i[institutional_filer_id period_of_report cusip put_call share_type]
    )
  end

  it "enforces one institutional report per shared filing" do
    report = create(:institutional_report)

    duplicate = report.dup
    duplicate.filing_id = report.filing_id

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "uses report sequence as the manager key" do
    report = create(:institutional_report)
    first = create(:institutional_report_manager, institutional_report: report, sequence_no: 1)
    second = create(:institutional_report_manager, institutional_report: report, sequence_no: 2)

    expect(report.institutional_report_managers).to contain_exactly(first, second)
    expect { create(:institutional_report_manager, institutional_report: report, sequence_no: 1) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "keeps same-CUSIP rows distinct by row sequence" do
    report = create(:institutional_report)
    first = create(:institutional_holding, institutional_report: report, row_seq: 1, put_call: nil)
    second = create(:institutional_holding, institutional_report: report, row_seq: 2, put_call: "Call")

    expect(report.institutional_holdings).to contain_exactly(first, second)
    expect(report.institutional_holdings.where(cusip: "037833100").count).to eq(2)
    expect { create(:institutional_holding, institutional_report: report, row_seq: 1) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "permits skipped pre-XML reports and amendment distinctions" do
    report = create(
      :institutional_report,
      status: "skipped",
      submission_type: "13F-HR/A",
      amendment_type: "RESTATEMENT"
    )

    expect(report).to be_skipped
    expect(report).to be_amendment
    expect(report).to be_restatement
    expect(report).not_to be_new_holdings
  end

  it "resolves the latest base plus later NEW HOLDINGS in SQL" do
    filer = create(:institutional_filer)
    period = Date.new(2026, 3, 31)
    base = create(
      :institutional_report,
      institutional_filer: filer,
      period_of_report: period,
      filed_at: Time.utc(2026, 5, 15),
      filing: create(:filing, cik: filer.cik, form_type: "13F-HR")
    )
    restatement = create(
      :institutional_report,
      institutional_filer: filer,
      period_of_report: period,
      filed_at: Time.utc(2026, 5, 20),
      amendment_type: "RESTATEMENT",
      submission_type: "13F-HR/A",
      filing: create(:filing, cik: filer.cik, form_type: "13F-HR/A")
    )
    new_holdings = create(
      :institutional_report,
      institutional_filer: filer,
      period_of_report: period,
      filed_at: Time.utc(2026, 5, 21),
      amendment_type: "NEW HOLDINGS",
      submission_type: "13F-HR/A",
      filing: create(:filing, cik: filer.cik, form_type: "13F-HR/A")
    )
    create(:institutional_holding, institutional_report: base, row_seq: 1)
    replacement = create(:institutional_holding, institutional_report: restatement, row_seq: 1)
    addition = create(:institutional_holding, institutional_report: new_holdings, row_seq: 1, cusip: "594918104")

    effective = InstitutionalReport.effective_holdings_for(institutional_filer: filer, period_of_report: period)

    expect(effective.map(&:id)).to contain_exactly(replacement.id, addition.id)
    expect(effective.map(&:institutional_report_id)).not_to include(base.id)
  end
end
