# frozen_string_literal: true

require "rails_helper"

RSpec.describe ArchiveVerification do
  it "probes bounded expected documents and omits paths and bodies from results" do
    filing = create(:filing, raw_path: "raw.txt")
    create(:institutional_report, cover_raw_path: "cover.xml", information_raw_path: "table.xml")
    archive = instance_double(FilingArchive)
    allow(archive).to receive(:probe).with("raw.txt").and_return("present")
    allow(archive).to receive(:probe).with("cover.xml").and_return("missing")
    allow(archive).to receive(:probe).with("table.xml").and_return("empty")
    result = described_class.new(archive:).call
    expect(result).to include(scanned_filings: 2, checked_documents: 3, has_more: false, metadata_only: true)
    expect(result.fetch(:status_counts)).to eq("present" => 1, "missing" => 1, "empty" => 1)
    expect(result.fetch(:documents).first).to include("filing_id" => filing.id, "kind" => "submission")
    expect(result.fetch(:documents).flat_map(&:keys)).not_to include("path", "body")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "pages filings under a pinned ID ceiling, including skipped reports without fabricated documents" do
    first = create(:filing)
    skipped = create(:institutional_report, status: "skipped")
    archive = instance_double(FilingArchive, probe: "missing_path")
    batch = described_class.new(limit: 1, archive:).call
    expect(batch).to include(scanned_filings: 1, has_more: true, next_after_id: first.id)
    create(:filing)
    second = described_class.new(limit: 1, after_id: batch.fetch(:next_after_id), filing_ceiling: batch.fetch(:filing_ceiling), archive:).call
    expect(second).to include(scanned_filings: 1, checked_documents: 0, has_more: false, next_after_id: nil)
    expect(second.fetch(:filing_ceiling)).to eq(skipped.filing_id)
    expect(second.dig(:coverage, :by_form, "13F-HR", "skipped_filings")).to eq(1)
  end

  it "validates limits and continuation arguments and returns explicit empty results" do
    [ { limit: 0 }, { limit: 501 }, { after_id: -1 }, { filing_ceiling: -1 }, { limit: "all" } ].each do |attributes|
      expect { described_class.new(**attributes) }.to raise_error(ArgumentError)
    end
    expect(described_class.new.call).to include(scanned_filings: 0, checked_documents: 0, has_more: false)
  end
end
