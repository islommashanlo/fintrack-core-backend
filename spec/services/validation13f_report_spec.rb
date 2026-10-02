# frozen_string_literal: true

require "rails_helper"

RSpec.describe Validation13fReport do
  def report
    described_class.new
  end

  def check_titled(pattern)
    report.checks.find { |check| check.title.match?(pattern) } || raise("no check matching #{pattern.inspect}")
  end

  it "passes a clean parsed NT report" do
    cover = Form13fCoverParser.parse(form13f_cover(:notice_2026_q1))
    filing = create(
      :filing, accession_no: "0002124041-26-000002", cik: cover.filer.cik, form_type: "13F-NT",
      filed_on: Date.new(2026, 5, 15), filed_at: Time.utc(2026, 5, 15, 20, 0), period_of_report: cover.period_of_report
    )
    Form13fIngestor.call(filing:, cover:, holdings: [], value_unit: nil, raw_paths: { cover: "cover.xml" })

    expect(report).not_to be_failed
    expect(check_titled(/reporting manager/).level).to eq(:pass)
    expect(check_titled(/required XML archive paths/).level).to eq(:pass)
  end

  it "flags count, value, unit, CUSIP, share and amendment integrity issues" do
    cover = Form13fCoverParser.parse(form13f_cover(:recent_2026_q1))
    filing = create(
      :filing, accession_no: "0002135539-26-000001", cik: cover.filer.cik, form_type: "13F-HR",
      filed_on: Date.new(2026, 5, 15), filed_at: Time.utc(2026, 5, 15, 20, 0), period_of_report: cover.period_of_report
    )
    row = Form13fInformationTableParser.parse(form13f_information(:recent_2026_q1)).first
      .with(cusip: "bad", shares: BigDecimal("0"))
    Form13fIngestor.call(
      filing:, cover:, holdings: [ row ], value_unit: "unresolved",
      raw_paths: { cover: "cover.xml", information: "information.xml" }
    )
    create(:institutional_report, institutional_filer: InstitutionalFiler.find_by!(cik: cover.filer.cik),
           period_of_report: Date.new(2026, 9, 30), table_value_total: BigDecimal("131295241000"),
           filed_at: Time.utc(2026, 8, 15), cover_raw_path: "later-cover.xml", information_raw_path: "later-info.xml",
           filing: create(:filing, cik: cover.filer.cik, form_type: "13F-HR"))

    expect(check_titled(/entry-count mismatches/).level).to eq(:warn)
    expect(check_titled(/value-total mismatches/).level).to eq(:warn)
    expect(check_titled(/malformed CUSIP/).level).to eq(:warn)
    expect(check_titled(/zero or negative/).level).to eq(:warn)
    expect(check_titled(/unknown value units/).level).to eq(:warn)
    expect(check_titled(/1000x/).level).to eq(:warn)
  end

  it "fails on missing archives, unresolved amendments and parse failures" do
    filer = create(:institutional_filer)
    report_record = create(
      :institutional_report, institutional_filer: filer, cover_raw_path: nil, information_raw_path: nil,
      filing: create(:filing, cik: filer.cik, form_type: "13F-HR")
    )
    amendment_period = Date.new(2027, 3, 31)
    create(
      :institutional_report, institutional_filer: filer, period_of_report: amendment_period,
      amendment_type: "NEW HOLDINGS", submission_type: "13F-HR/A",
      filing: create(:filing, cik: filer.cik, form_type: "13F-HR/A", period_of_report: amendment_period)
    )
    ParseFailure.record!(report_record.filing.accession_no, "Form13fCoverParser::MalformedError: bad XML")

    expect(report).to be_failed
    expect(check_titled(/missing required XML/).level).to eq(:fail)
    expect(check_titled(/no resolvable original/).level).to eq(:warn)
    expect(check_titled(/unresolved 13F parse failures/).level).to eq(:fail)
  end

  it "warns when valid CUSIPs or multi-quarter diffs are not covered" do
    filer = create(:institutional_filer)
    first_period = Date.new(2025, 12, 31)
    second_period = Date.new(2026, 3, 31)
    first = create_report(filer, first_period, Time.utc(2026, 2, 14))
    second = create_report(filer, second_period, Time.utc(2026, 5, 15))
    create(:institutional_holding, institutional_report: first, row_seq: 1, cusip: "037833100")
    create(:institutional_holding, institutional_report: second, row_seq: 1, cusip: "037833100")

    expect(check_titled(/lack an unambiguous mapping/).level).to eq(:warn)
    expect(check_titled(/no materialized position diffs/).level).to eq(:warn)
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
