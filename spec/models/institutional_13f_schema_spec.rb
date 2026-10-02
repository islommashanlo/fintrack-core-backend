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
end
