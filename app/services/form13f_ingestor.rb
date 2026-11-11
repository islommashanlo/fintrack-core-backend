# frozen_string_literal: true

# Writes one parsed 13F report to the database.
#
# Every report and holding is upserted on a database-backed natural key. Reported
# values remain in value_reported; normalization and integrity checks only populate
# separate fields and flags.
class Form13fIngestor
  FORM_TYPES = %w[13F-HR 13F-HR/A 13F-NT].freeze
  DEFAULT_STATUS = "parsed"

  class MismatchError < StandardError; end
  class NaturalKeyCollisionError < StandardError; end

  def self.call(filing:, cover:, holdings:, value_unit:, raw_paths: {})
    new(filing:, cover:, holdings:, value_unit:, raw_paths:).call
  end

  def self.skip!(filing:, reason:)
    new(filing:, cover: nil, holdings: [], value_unit: nil, raw_paths: {}).skip!(reason)
  end

  def initialize(filing:, cover:, holdings:, value_unit:, raw_paths: {})
    @filing = filing
    @cover = cover
    @holdings = holdings
    @value_unit = value_unit
    @raw_paths = raw_paths
  end

  def call
    verify!
    assert_unique_sequences!(@cover.other_managers.map(&:sequence_no), "cover manager")
    assert_unique_sequences!(@cover.included_managers.map(&:sequence_no), "manager")
    assert_unique_sequences!(@holdings.map(&:row_seq), "holding")

    Filing.transaction do
      institutional_filer = upsert_institutional_filer
      report = upsert_report(institutional_filer)
      upsert_managers(report)
      upsert_other_managers(report)
      upsert_holdings(report)
      update_filing
    end

    @filing.reload
  end

  def skip!(reason)
    raise ArgumentError, "pre-XML report is missing period_of_report" if @filing.period_of_report.nil?

    Filing.transaction do
      institutional_filer = upsert_institutional_filer
      report = InstitutionalReport.create!(
        filing: @filing,
        institutional_filer:,
        period_of_report: @filing.period_of_report,
        filed_at: @filing.filed_at,
        submission_type: @filing.form_type,
        report_type: "PRE-XML 13F",
        status: "skipped",
        suspect: false,
        suspect_reason: reason
      )
      @filing.update!(parse_status: "parsed", accepted_at: @filing.accepted_at || @filing.filed_at,
                      ingested_at: @filing.ingested_at || Time.current, parsed_at: Time.current)
      report
    end
  end

  private

  def verify!
    raise MismatchError, "missing 13F cover document" unless @cover
    raise MismatchError, "unsupported 13F submission type: #{@cover.submission_type.inspect}" unless FORM_TYPES.include?(@cover.submission_type)
    unless @filing.form_type == @cover.submission_type
      raise MismatchError, "expected #{@filing.form_type}, cover is #{@cover.submission_type}"
    end
    return if @filing.cik == @cover.filer.cik

    raise MismatchError, "expected filer #{@filing.cik}, cover is #{@cover.filer.cik}"
  end

  def upsert_institutional_filer
    InstitutionalFiler.insert_all(
      [ { cik: @cover ? @cover.filer.cik : @filing.cik, name: @cover&.filer&.name || @filing.cik,
          created_at: Time.current, updated_at: Time.current } ],
      unique_by: :cik
    )
    InstitutionalFiler.find_by!(cik: @cover ? @cover.filer.cik : @filing.cik)
  end

  def upsert_report(institutional_filer)
    InstitutionalReport.upsert(
      {
        filing_id: @filing.id,
        institutional_filer_id: institutional_filer.id,
        period_of_report: @cover.period_of_report,
        filed_at: @filing.filed_at,
        submission_type: @cover.submission_type,
        report_type: @cover.report_type,
        amendment_type: @cover.amendment_type,
        amendment_number: @cover.amendment_number,
        other_managers_recorded: true,
        other_included_managers_count: @cover.other_included_managers_count,
        table_entry_total: @cover.table_entry_total,
        table_value_total: @cover.table_value_total,
        cover_value_unit: canonical_unit,
        cover_raw_path: @raw_paths[:cover],
        information_raw_path: @raw_paths[:information],
        status: DEFAULT_STATUS,
        suspect: report_suspect_reasons.any?,
        suspect_reason: report_suspect_reasons.presence&.join(","),
        created_at: Time.current,
        updated_at: Time.current
      },
      unique_by: :index_institutional_reports_on_filing_id
    )
    InstitutionalReport.find_by!(filing_id: @filing.id)
  end

  def upsert_managers(report)
    rows = @cover.included_managers.map do |manager|
      manager.to_h.merge(
        institutional_report_id: report.id,
        created_at: Time.current,
        updated_at: Time.current
      )
    end
    return if rows.empty?

    InstitutionalReportManager.upsert_all(rows, unique_by: :index_13f_report_managers_on_report_and_sequence)
  end

  # Cover sequence numbers are document ordinals, independent of the included
  # managers' reported sequence numbers referenced by information-table rows.
  def upsert_other_managers(report)
    rows = @cover.other_managers.map do |manager|
      manager.to_h.merge(institutional_report_id: report.id, created_at: Time.current, updated_at: Time.current)
    end
    return if rows.empty?

    InstitutionalReportOtherManager.upsert_all(rows, unique_by: :index_13f_other_managers_on_report_and_sequence)
  end

  def upsert_holdings(report)
    rows = @holdings.map do |holding|
      normalized = Form13fValueNormalizer.normalize(value_reported: holding.value_reported, value_unit: @value_unit)
      suspect_reasons = holding_suspect_reasons(holding, normalized)

      holding.to_h.merge(
        institutional_report_id: report.id,
        value_unit: normalized.value_unit,
        value_usd: normalized.value_usd,
        suspect: suspect_reasons.any?,
        suspect_reason: suspect_reasons.presence&.join(","),
        created_at: Time.current,
        updated_at: Time.current
      ).except(:row_seq)
        .merge(row_seq: holding.row_seq)
    end
    return if rows.empty?

    InstitutionalHolding.upsert_all(rows, unique_by: :index_13f_holdings_on_report_and_row)
  end

  def update_filing
    @filing.update!(
      period_of_report: @cover.period_of_report,
      accepted_at: @filing.accepted_at || @filing.filed_at,
      ingested_at: @filing.ingested_at || Time.current,
      parse_status: "parsed",
      parsed_at: Time.current
    )
  end

  def canonical_unit
    return nil if @value_unit.nil?

    Form13fValueNormalizer.normalize(value_reported: 0, value_unit: @value_unit).value_unit
  end

  def report_suspect_reasons
    @report_suspect_reasons ||= begin
      reasons = []
      if @cover.table_entry_total && @cover.table_entry_total != @holdings.length
        reasons << "entry_count_mismatch"
      end
      if @cover.table_value_total && @holdings.any?
        reported_sum = @holdings.sum(&:value_reported)
        reasons << "value_total_mismatch" unless reported_sum == @cover.table_value_total
      end
      reasons
    end
  end

  def holding_suspect_reasons(holding, normalized)
    reasons = []
    reasons << normalized.suspect_reason if normalized.suspect
    reasons << "invalid_cusip_shape" unless holding.cusip&.match?(/\A[0-9A-Z]{9}\z/)
    reasons << "non_positive_shares" if holding.shares <= 0
    reasons
  end

  def assert_unique_sequences!(sequences, kind)
    duplicate = sequences.tally.find { |_sequence, count| count > 1 }&.first
    return unless duplicate

    raise NaturalKeyCollisionError, "duplicate #{kind} natural key in one batch: #{duplicate.inspect}"
  end
end
