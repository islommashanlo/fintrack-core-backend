# frozen_string_literal: true

require "rails_helper"

RSpec.describe Form13fIngestor do
  def cover(name)
    Form13fCoverParser.parse(form13f_cover(name))
  end

  def holdings(name)
    Form13fInformationTableParser.parse(form13f_information(name))
  end

  def filing_for(name, form_type: nil)
    fixture = cover(name)
    create(
      :filing,
      accession_no: {
        recent_2026_q1: "0002135539-26-000001",
        amendment_2026_q1: "0002106181-26-000005",
        notice_2026_q1: "0002124041-26-000002",
        post_cutoff_2023_q1: "0001965819-23-000010"
      }.fetch(name),
      cik: fixture.filer.cik,
      form_type: form_type || fixture.submission_type,
      filed_on: fixture.period_of_report + 45,
      filed_at: Time.utc(2026, 5, 15, 20, 0),
      period_of_report: fixture.period_of_report,
      parse_status: "pending"
    )
  end

  def ingest(name, value_unit: "whole_dollars", rows: nil, raw_paths: {})
    described_class.call(
      filing: filing_for(name), cover: cover(name), holdings: rows || holdings(name),
      value_unit:, raw_paths:
    )
  end

  it "ingests a report, manager rows and holdings with normalized values" do
    ingest(:post_cutoff_2023_q1, raw_paths: { cover: "13f/cover.xml", information: "13f/info.xml" })

    report = InstitutionalReport.sole
    expect(report).to have_attributes(
      status: "parsed", period_of_report: Date.new(2023, 3, 31), table_entry_total: 56,
      cover_raw_path: "13f/cover.xml", information_raw_path: "13f/info.xml", suspect: false
    )
    expect(report.institutional_report_managers.count).to eq(2)
    expect(report.institutional_holdings.count).to eq(56)
    expect(report.institutional_holdings.where(other_manager: "1").count).to be > 0
    expect(report.institutional_holdings.first.value_usd).to eq(report.institutional_holdings.first.value_reported)
    expect(report.filing.parse_status).to eq("parsed")
  end

  it "is idempotent and preserves the same-CUSIP multi-row table" do
    fixture = :post_cutoff_2023_q1
    filing = filing_for(fixture)
    rows = holdings(fixture)
    described_class.call(filing:, cover: cover(fixture), holdings: rows, value_unit: "whole_dollars")
    before = [ InstitutionalReport.count, InstitutionalReportManager.count, InstitutionalHolding.count ]

    described_class.call(filing:, cover: cover(fixture), holdings: rows, value_unit: "whole_dollars")

    expect([ InstitutionalReport.count, InstitutionalReportManager.count, InstitutionalHolding.count ]).to eq(before)
    expect(InstitutionalHolding.where(institutional_report: InstitutionalReport.sole).count).to eq(56)
  end

  it "does not collapse same-CUSIP rows with different put/call details" do
    fixture = :combination_put_call_2024_q2
    filing = create(
      :filing, accession_no: "0000902664-24-005149", cik: cover(fixture).filer.cik,
      form_type: "13F-HR", filed_on: Date.new(2024, 8, 14), filed_at: Time.utc(2024, 8, 14, 20, 0),
      period_of_report: Date.new(2024, 6, 30), parse_status: "pending"
    )
    described_class.call(filing:, cover: cover(fixture), holdings: holdings(fixture), value_unit: "whole_dollars")

    repeated = InstitutionalHolding.where(cusip: "88579Y101").order(:row_seq)
    expect(repeated.map(&:put_call)).to eq([ nil, "Call" ])
  end

  it "rejects a duplicate row key before writing any 13F rows" do
    rows = holdings(:recent_2026_q1)
    duplicate_rows = rows.first(2).map.with_index { |row, index| index.zero? ? row : row.with(row_seq: 1) }
    filing = filing_for(:recent_2026_q1)

    expect do
      described_class.call(filing:, cover: cover(:recent_2026_q1), holdings: duplicate_rows, value_unit: "whole_dollars")
    end.to raise_error(Form13fIngestor::NaturalKeyCollisionError)
    expect(InstitutionalFiler.count).to eq(0)
    expect(InstitutionalReport.count).to eq(0)
    expect(InstitutionalHolding.count).to eq(0)
  end

  it "records a 13F-NT without holdings" do
    ingest(:notice_2026_q1, value_unit: nil, rows: [])

    expect(InstitutionalReport.sole).to have_attributes(status: "parsed", table_entry_total: nil, suspect: false)
    expect(InstitutionalHolding.count).to eq(0)
  end

  it "retains NEW HOLDINGS and RESTATEMENT amendments as distinct report types" do
    new_holdings = ingest(:amendment_2026_q1, value_unit: "whole_dollars")
    new_report = InstitutionalReport.find_by!(filing: new_holdings)

    restatement_cover = cover(:amendment_2026_q1).with(amendment_type: "RESTATEMENT")
    restatement_filing = create(
      :filing,
      accession_no: "0002106181-26-000006",
      cik: "0002106181",
      form_type: "13F-HR/A",
      filed_on: Date.new(2026, 5, 16),
      filed_at: Time.utc(2026, 5, 16, 20, 0),
      period_of_report: Date.new(2026, 3, 31),
      parse_status: "pending"
    )
    described_class.call(
      filing: restatement_filing, cover: restatement_cover,
      holdings: holdings(:amendment_2026_q1), value_unit: "whole_dollars"
    )

    expect(new_report.reload).to be_new_holdings
    expect(InstitutionalReport.find_by!(filing: restatement_filing)).to be_restatement
    expect(InstitutionalReport.where(period_of_report: Date.new(2026, 3, 31)).count).to eq(2)
  end

  it "flags anomalies while retaining reported values" do
    rows = holdings(:recent_2026_q1).first(1).map { |row| row.with(cusip: "bad", shares: BigDecimal("0")) }
    ingest(:recent_2026_q1, value_unit: "unresolved", rows: rows)

    holding = InstitutionalHolding.sole
    expect(holding).to have_attributes(
      value_reported: rows.first.value_reported, value_usd: nil, suspect: true,
      suspect_reason: include("unknown_value_unit", "invalid_cusip_shape", "non_positive_shares")
    )
    expect(InstitutionalReport.sole.suspect_reason).to include("entry_count_mismatch")
  end

  it "records pre-XML filings as skipped without a parse failure" do
    filing = create(
      :filing, accession_no: "0000000123-99-000001", cik: "0000000123", form_type: "13F-HR",
      filed_on: Date.new(1999, 11, 15), filed_at: Time.utc(1999, 11, 15, 20, 0),
      period_of_report: Date.new(1999, 9, 30), parse_status: "pending"
    )

    report = described_class.skip!(filing:, reason: "pre_xml_information_table")

    expect(report).to have_attributes(status: "skipped", report_type: "PRE-XML 13F")
    expect(filing.reload.parse_status).to eq("parsed")
    expect(ParseFailure.count).to eq(0)
  end
end
