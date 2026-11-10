# frozen_string_literal: true

module ActivityScoring
  class InstitutionalInputsQuery
    ReportSource = Data.define(:visible_reports)

    def initialize(row:, bounds:, rules:)
      @row = row
      @bounds = bounds
      @rules = rules
    end

    def call
      time = @row.fetch("occurred_at")
      period = @row.fetch("period_of_report")
      prior = period.beginning_of_quarter - 1.day
      history_start = period << (@rules.fetch("history_quarters") * 3)
      visible = InstitutionalReportScope.new(as_of: time, max_report_id: @bounds.fetch("reports"),
        max_filing_id: @bounds.fetch("filings")).visible_reports
        .where(period_of_report: (history_start.beginning_of_quarter - 1.day)..period)
        .where("institutional_reports.institutional_filer_id = :fund OR institutional_reports.period_of_report IN (:periods)",
          fund: @row.fetch("fund_id"), periods: [ prior, period ])
      key_holdings = InstitutionalHolding.where(cusip: @row.fetch("cusip"), share_type: @row.fetch("share_type"))
        .where("COALESCE(put_call, '') = ? AND institutional_holdings.id <= ?", @row["put_call"].to_s, @bounds.fetch("holdings"))
      candidates = InstitutionalReport.where(id: visible.except(:select).select(:id), period_of_report: [ prior, period ])
        .joins(:institutional_holdings).merge(key_holdings).select(:institutional_filer_id)
      visible = visible.where("institutional_reports.institutional_filer_id = ? OR institutional_reports.institutional_filer_id IN (#{candidates.to_sql})",
        @row.fetch("fund_id"))
      # Signed event links retain their exact subject-fund comparison report set.
      selected = visible.where(<<~SQL.squish, fund: @row.fetch("fund_id"), periods: [ prior, period ], ids: @row.fetch("context_report_ids"))
        institutional_reports.institutional_filer_id <> :fund OR institutional_reports.period_of_report NOT IN (:periods)
          OR institutional_reports.id IN (:ids)
      SQL
      own_reports = selected.where(institutional_filer_id: @row.fetch("fund_id")).except(:select).select(:id)
      holdings = InstitutionalHolding.where("institutional_report_id IN (#{own_reports.to_sql}) OR id IN (#{key_holdings.select(:id).to_sql})")
      diffs = InstitutionalPositionDiffQuery.new(report_scope: ReportSource.new(visible_reports: selected),
        max_holding_id: @bounds.fetch("holdings"), include_context: true, holding_scope: holdings).to_sql
      binds = { time:, period:, history_start:, fund: @row.fetch("fund_id"), cusip: @row.fetch("cusip"),
                put_call: @row["put_call"].to_s, share_type: @row.fetch("share_type"),
                change: position_data.fetch("change_type"), value: @row["value"], ids: @row.fetch("context_report_ids") }
      Api::V1::CursorPage.sql_rows(ApplicationRecord.sanitize_sql([ <<~SQL, binds ])).sole
        WITH visible AS (#{visible.to_sql}), raw_diffs AS (#{diffs}), report_checks AS (
          #{report_checks_sql}
        ), checked_diffs AS (
          SELECT d.*, q.known_at, q.structure_complete, q.values_complete
          FROM raw_diffs d CROSS JOIN LATERAL (
            SELECT MAX(c.known_filed_at) AS known_at,
              BOOL_AND(c.structure_complete) AND COUNT(*) = cardinality(d.current_context_ids || d.prior_context_ids) AS structure_complete,
              BOOL_AND(c.values_complete) AS values_complete
            FROM report_checks c WHERE c.id = ANY(d.current_context_ids || d.prior_context_ids)
          ) q
          WHERE d.prior_period_of_report = date_trunc('quarter', d.period_of_report)::date - 1
        ), history AS (
          SELECT * FROM checked_diffs WHERE institutional_filer_id = :fund
            AND period_of_report >= :history_start AND period_of_report < :period AND known_at < :time
            AND structure_complete AND values_complete AND NOT current_suspect AND NOT prior_suspect
            AND value_usd_delta IS NOT NULL
        ), event_context AS (
          SELECT * FROM report_checks WHERE id IN (:ids)
        )
        SELECT
          EXISTS(SELECT 1 FROM checked_diffs WHERE institutional_filer_id = :fund AND period_of_report = :period
            AND cusip = :cusip AND COALESCE(put_call, '') = :put_call AND share_type = :share_type
            AND change_type = :change AND structure_complete) AS event_eligible,
          (SELECT COUNT(*) FROM history WHERE (shares_delta > 0) = (:change IN ('new', 'add'))) AS history_count,
          (SELECT COUNT(*) FROM history WHERE (shares_delta > 0) = (:change IN ('new', 'add')) AND ABS(value_usd_delta) <= :value) AS history_less_or_equal_count,
          (SELECT MIN(known_at) FROM history WHERE (shares_delta > 0) = (:change IN ('new', 'add'))) AS history_first_at,
          (SELECT MAX(known_at) FROM history WHERE (shares_delta > 0) = (:change IN ('new', 'add'))) AS history_last_at,
          (SELECT COUNT(DISTINCT institutional_filer_id) FROM checked_diffs WHERE period_of_report = :period
            AND cusip = :cusip AND COALESCE(put_call, '') = :put_call AND share_type = :share_type
            AND change_type = :change AND structure_complete AND known_at <= :time) AS participant_count,
          ARRAY(SELECT id FROM event_context ORDER BY id) AS checked_report_ids,
          ARRAY(SELECT id FROM event_context WHERE NOT structure_complete ORDER BY id) AS invalid_report_ids,
          ARRAY(SELECT id FROM event_context WHERE NOT values_complete ORDER BY id) AS value_incomplete_report_ids
      SQL
    end

    private

    def position_data
      data = @row.fetch("position_data")
      data.is_a?(String) ? JSON.parse(data) : data
    end

    def report_checks_sql
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
          FROM institutional_holdings h WHERE h.institutional_report_id = r.id AND h.id <= #{@bounds.fetch('holdings')}
        ) h
        WHERE r.id IN (SELECT unnest(current_context_ids || prior_context_ids) FROM raw_diffs) OR r.id IN (:ids)
      SQL
    end
  end
end
