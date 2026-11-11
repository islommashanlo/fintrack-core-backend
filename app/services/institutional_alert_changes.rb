# frozen_string_literal: true

class InstitutionalAlertChanges
  ReportSource = Data.define(:visible_reports)
  attr_reader :reports, :max_holding_id

  def initialize(report:, as_of:)
    @report = report
    @reports = InstitutionalReportScope.new(as_of:, max_report_id: InstitutionalReport.maximum(:id) || 0,
      max_filing_id: Filing.maximum(:id) || 0)
    @max_holding_id = InstitutionalHolding.maximum(:id) || 0
  end

  def sql
    visible = reports.visible_reports.where(institutional_filer_id: @report.institutional_filer_id,
      period_of_report: (@report.period_of_report << 3).end_of_quarter..(@report.period_of_report >> 3).end_of_quarter)
    source = ReportSource.new(visible_reports: visible)
    diffs = InstitutionalPositionDiffQuery.new(institutional_filer_id: @report.institutional_filer_id,
      report_scope: source, max_holding_id:, include_context: true).to_sql
    <<~SQL
      WITH visible AS (#{visible.to_sql}), raw_diffs AS (#{diffs}), checks AS (
        #{InstitutionalReportChecks.sql(max_holding_id:)}
      ), checked AS (
        SELECT d.*, q.values_complete, evidence.ids AS evidence_report_ids, latest.filing_id AS primary_filing_id,
          CASE d.change_type WHEN 'add' THEN 'added' WHEN 'trim' THEN 'reduced' WHEN 'exit' THEN 'exited' ELSE 'new' END AS api_change_type
        FROM raw_diffs d CROSS JOIN LATERAL (
          SELECT BOOL_AND(c.structure_complete) AS complete, BOOL_AND(c.values_complete) AS values_complete,
            COUNT(*) AS report_count FROM checks c WHERE c.id = ANY(d.current_context_ids || d.prior_context_ids)
        ) q
        CROSS JOIN LATERAL (
          SELECT ARRAY(SELECT r.id FROM visible r WHERE r.id = ANY(d.current_context_ids || d.prior_context_ids)
            OR (r.submission_type = '13F-HR' AND r.amendment_type IS NULL AND EXISTS (
              SELECT 1 FROM visible m WHERE m.id = ANY(d.current_context_ids || d.prior_context_ids)
                AND m.period_of_report = r.period_of_report AND m.amendment_type IS NOT NULL
                AND (r.known_filed_at, r.known_accession) < (m.known_filed_at, m.known_accession)
            )) ORDER BY r.id) AS ids
        ) evidence
        CROSS JOIN LATERAL (
          SELECT r.filing_id FROM visible r WHERE r.id = ANY(d.current_context_ids || d.prior_context_ids)
          ORDER BY r.known_filed_at DESC, r.known_accession DESC LIMIT 1
        ) latest
        WHERE d.prior_period_of_report = date_trunc('quarter', d.period_of_report)::date - 1
          AND d.period_of_report = (date_trunc('quarter', d.period_of_report) + INTERVAL '3 months - 1 day')::date
          AND q.complete AND q.report_count = cardinality(d.current_context_ids || d.prior_context_ids)
      )
      SELECT checked.*, encode(sha256(convert_to(jsonb_build_array(institutional_filer_id, period_of_report,
        prior_period_of_report, cusip, put_call, share_type, current_context_ids, prior_context_ids,
        evidence_report_ids)::text, 'UTF8')), 'hex') AS event_key
      FROM checked
    SQL
  end
end
