# frozen_string_literal: true

# Expected source documents for successfully processed local filings.
class ArchiveInventory
  COUNTS = %w[parsed_filings skipped_filings missing_reports expected_documents recorded_documents missing_paths].freeze

  def initialize(filing_ids: nil)
    @filing_ids = filing_ids
  end

  def filings
    scope = Filing.parsed.where(form_type: Filing::SEC_INGEST_TYPES)
      .joins("LEFT JOIN institutional_reports r ON r.filing_id = filings.id")
    scope = scope.where(id: @filing_ids) if @filing_ids
    scope.select("filings.id AS filing_id", "filings.form_type", "filings.accession_no", "filings.raw_path",
      "r.id AS report_id", "r.status AS report_status", "r.cover_raw_path", "r.information_raw_path")
  end

  def documents_sql
    <<~SQL
      SELECT filing_id, form_type, accession_no, 'submission' AS kind, raw_path AS path FROM candidates
      WHERE form_type IN ('4', '4/A')
      UNION ALL
      SELECT filing_id, form_type, accession_no, 'cover' AS kind, cover_raw_path AS path FROM candidates
      WHERE form_type IN ('13F-HR', '13F-HR/A', '13F-NT') AND COALESCE(report_status, '') <> 'skipped'
      UNION ALL
      SELECT filing_id, form_type, accession_no, 'information_table' AS kind, information_raw_path AS path FROM candidates
      WHERE form_type IN ('13F-HR', '13F-HR/A') AND COALESCE(report_status, '') <> 'skipped'
    SQL
  end

  def documents
    Filing.connection.select_all("WITH candidates AS (#{filings.to_sql}) #{documents_sql} ORDER BY filing_id, kind").to_a
  end

  def coverage
    rows = Filing.connection.select_all(<<~SQL).to_a.index_by { |row| row.fetch("form_type") }
      WITH candidates AS (#{filings.to_sql}), documents AS (#{documents_sql}), document_counts AS (
        SELECT filing_id, COUNT(*) AS expected_documents,
          COUNT(*) FILTER (WHERE path IS NOT NULL AND path !~ '^[[:space:]]*$') AS recorded_documents,
          COUNT(*) FILTER (WHERE path IS NULL OR path ~ '^[[:space:]]*$') AS missing_paths
        FROM documents GROUP BY filing_id
      )
      SELECT c.form_type, COUNT(*) AS parsed_filings,
        COUNT(*) FILTER (WHERE c.report_status = 'skipped') AS skipped_filings,
        COUNT(*) FILTER (WHERE c.form_type IN ('13F-HR', '13F-HR/A', '13F-NT') AND c.report_id IS NULL) AS missing_reports,
        COALESCE(SUM(d.expected_documents), 0) AS expected_documents,
        COALESCE(SUM(d.recorded_documents), 0) AS recorded_documents,
        COALESCE(SUM(d.missing_paths), 0) AS missing_paths
      FROM candidates c LEFT JOIN document_counts d USING (filing_id) GROUP BY c.form_type
    SQL
    { filesystem_checked: false, by_form: Filing::SEC_INGEST_TYPES.to_h do |form|
      [ form, COUNTS.to_h { |key| [ key, rows.dig(form, key).to_i ] } ]
    end }
  end
end
