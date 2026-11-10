# frozen_string_literal: true

# Shared read scope for reports that were known at a given time. A notice never
# becomes a holdings base, and an unresolved additive amendment has no holdings.
class InstitutionalReportScope
  def initialize(as_of:, max_report_id: nil, max_filing_id: nil, max_holding_id: nil, report_ids: nil)
    @as_of = as_of
    @max_report_id = max_report_id
    @max_filing_id = max_filing_id
    @max_holding_id = max_holding_id
    @report_ids = report_ids
  end

  def visible_reports
    scope = InstitutionalReport.joins(:filing).parsed
      .where(filings: { parse_status: "parsed", form_type: Filing::FORM13F_TYPES })
      .where("COALESCE(filings.filed_at, institutional_reports.filed_at) <= ?", @as_of)
    scope = scope.where("institutional_reports.id <= ?", @max_report_id) if @max_report_id
    scope = scope.where("filings.id <= ?", @max_filing_id) if @max_filing_id
    scope = scope.where(id: @report_ids) if @report_ids
    scope.select("institutional_reports.*", "COALESCE(filings.filed_at, institutional_reports.filed_at) AS known_filed_at",
                 "filings.accession_no AS known_accession")
  end

  def effective_reports
    InstitutionalReport.where(<<~SQL.squish)
      institutional_reports.id IN (
        WITH visible AS (#{visible_reports.to_sql}), bases AS (
          SELECT DISTINCT ON (institutional_filer_id, period_of_report) *
          FROM visible
          WHERE submission_type IN ('13F-HR', '13F-HR/A')
            AND (amendment_type IS NULL OR amendment_type = 'RESTATEMENT')
          ORDER BY institutional_filer_id, period_of_report, known_filed_at DESC, known_accession DESC
        )
        SELECT id FROM bases
        UNION ALL
        SELECT additions.id FROM visible additions
        INNER JOIN bases ON bases.institutional_filer_id = additions.institutional_filer_id
          AND bases.period_of_report = additions.period_of_report
        WHERE additions.submission_type = '13F-HR/A' AND additions.amendment_type = 'NEW HOLDINGS'
          AND (additions.known_filed_at, additions.known_accession) > (bases.known_filed_at, bases.known_accession)
      )
    SQL
  end

  def holdings
    scope = InstitutionalHolding.where(institutional_report_id: effective_reports.select(:id))
    scope = scope.where("institutional_holdings.id <= ?", @max_holding_id) if @max_holding_id
    scope
  end
end
