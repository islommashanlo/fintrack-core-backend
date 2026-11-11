# frozen_string_literal: true

class InstitutionalReportChecks
  # Callers provide the bounded visible report CTE.
  def self.sql(max_holding_id:)
    <<~SQL
        SELECT r.id, r.known_filed_at,
          (NOT r.suspect AND r.table_entry_total IS NOT NULL AND r.table_entry_total >= 0
            AND r.table_entry_total = h.row_count AND r.table_value_total IS NOT NULL
            AND r.table_value_total >= 0 AND r.table_value_total = h.reported_total AND h.rows_valid
            AND (r.amendment_type IS NULL OR EXISTS (
              SELECT 1 FROM visible original WHERE original.institutional_filer_id = r.institutional_filer_id
                AND original.period_of_report = r.period_of_report AND original.submission_type = '13F-HR'
                AND original.amendment_type IS NULL
                AND (original.known_filed_at, original.known_accession) < (r.known_filed_at, r.known_accession)
            ))) AS structure_complete,
          h.values_valid AS values_complete
        FROM visible r CROSS JOIN LATERAL (
          SELECT COUNT(*) AS row_count, COALESCE(SUM(h.value_reported), 0) AS reported_total,
            COALESCE(BOOL_AND(h.cusip IS NOT NULL AND h.cusip ~ '^[0-9A-Z]{9}$' AND h.shares > 0
              AND h.shares::text NOT IN ('NaN', 'Infinity', '-Infinity')
              AND h.share_type IN ('SH', 'PRN') AND (h.put_call IS NULL OR h.put_call IN ('PUT', 'CALL'))
              AND h.value_reported >= 0 AND h.value_reported::text NOT IN ('NaN', 'Infinity', '-Infinity') AND NOT h.suspect), TRUE) AS rows_valid,
            COALESCE(BOOL_AND(h.value_usd IS NOT NULL AND h.value_usd >= 0 AND r.cover_value_unit IS NOT NULL
              AND h.value_usd::text NOT IN ('NaN', 'Infinity', '-Infinity')
              AND h.value_unit = r.cover_value_unit AND h.value_unit IN ('whole_dollars', 'thousands')
              AND h.value_usd = h.value_reported * CASE h.value_unit WHEN 'whole_dollars' THEN 1 WHEN 'thousands' THEN 1000 END), TRUE) AS values_valid
          FROM institutional_holdings h WHERE h.institutional_report_id = r.id AND h.id <= #{max_holding_id}
        ) h
    SQL
  end
end
