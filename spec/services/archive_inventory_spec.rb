# frozen_string_literal: true

require "rails_helper"

RSpec.describe ArchiveInventory do
  it "counts expected document paths by exact form and does not claim filesystem verification" do
    create(:filing, raw_path: "raw.txt")
    create(:filing, form_type: "4/A", raw_path: " \t\n")
    report = create(:institutional_report, cover_raw_path: "cover.xml", information_raw_path: nil)
    notice = create(:filing, form_type: "13F-NT")
    create(:institutional_report, filing: notice, submission_type: "13F-NT", cover_raw_path: "notice.xml")
    skipped = create(:filing, form_type: "13F-HR/A")
    create(:institutional_report, filing: skipped, status: "skipped")
    create(:filing, :pending)
    create(:filing, parse_status: "failed")
    result = described_class.new.coverage
    expect(result.fetch(:filesystem_checked)).to be(false)
    forms = result.fetch(:by_form)
    expect(forms.fetch("4")).to include("parsed_filings" => 1, "expected_documents" => 1, "recorded_documents" => 1, "missing_paths" => 0)
    expect(forms.fetch("4/A")).to include("missing_paths" => 1)
    expect(forms.fetch("13F-HR")).to include("expected_documents" => 2, "recorded_documents" => 1, "missing_paths" => 1)
    expect(forms.fetch("13F-NT")).to include("expected_documents" => 1, "recorded_documents" => 1)
    expect(forms.fetch("13F-HR/A")).to include("parsed_filings" => 1, "skipped_filings" => 1, "expected_documents" => 0)
    expect(described_class.new(filing_ids: [ report.filing_id ]).documents.pluck("kind")).to match_array(%w[cover information_table])
  end

  it "reports missing 13F report records and counts their required document references" do
    create(:filing, form_type: "13F-HR")
    result = described_class.new.coverage.fetch(:by_form).fetch("13F-HR")
    expect(result).to include("missing_reports" => 1, "expected_documents" => 2, "missing_paths" => 2)
  end
end
