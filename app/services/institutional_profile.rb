# frozen_string_literal: true

# Read-only SQL queries for an institution profile. Effective holdings are
# resolved in SQL so amendment semantics stay identical to the ingestion layer.
class InstitutionalProfile
  def initialize(institutional_filer:, as_of: Time.current)
    @institutional_filer = institutional_filer
    @as_of = as_of
  end

  def latest_report
    @latest_report ||= InstitutionalReport.parsed
      .where(institutional_filer_id: @institutional_filer.id)
      .where("filed_at IS NULL OR filed_at <= ?", @as_of)
      .order(period_of_report: :desc, filed_at: :desc, id: :desc)
      .first
  end

  def report_history(limit: 12)
    select(<<~SQL, as_of: @as_of, limit:)
      SELECT r.id,
             r.period_of_report,
             r.filed_at,
             r.submission_type,
             r.report_type,
             r.amendment_type,
             r.table_entry_total,
             r.table_value_total,
             r.cover_value_unit,
             r.suspect,
             f.cik AS filing_cik,
             f.accession_no
      FROM institutional_reports r
      INNER JOIN filings f ON f.id = r.filing_id
      WHERE r.institutional_filer_id = :institutional_filer_id
        AND r.status = 'parsed'
        AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
      ORDER BY r.period_of_report DESC, r.filed_at DESC NULLS LAST, r.id DESC
      LIMIT :limit
    SQL
  end

  def top_holdings(limit: 24)
    return [] unless latest_report

    select(<<~SQL, period_of_report: latest_report.period_of_report, limit:)
      WITH latest_base AS (
        SELECT r.id, COALESCE(r.filed_at, TIMESTAMP 'epoch') AS filed_at
        FROM institutional_reports r
        WHERE r.institutional_filer_id = :institutional_filer_id
          AND r.period_of_report = :period_of_report
          AND r.status = 'parsed'
          AND (r.amendment_type IS NULL OR r.amendment_type = 'RESTATEMENT')
        ORDER BY r.filed_at DESC NULLS LAST, r.id DESC
        LIMIT 1
      ), effective_reports AS (
        SELECT id FROM latest_base
        UNION ALL
        SELECT r.id
        FROM institutional_reports r
        CROSS JOIN latest_base b
        WHERE r.institutional_filer_id = :institutional_filer_id
          AND r.period_of_report = :period_of_report
          AND r.status = 'parsed'
          AND r.amendment_type = 'NEW HOLDINGS'
          AND COALESCE(r.filed_at, TIMESTAMP 'epoch') > b.filed_at
      )
      SELECT h.cusip,
             MIN(h.name_of_issuer) AS name_of_issuer,
             MIN(h.title_of_class) AS title_of_class,
             COALESCE(h.put_call, '') AS put_call,
             h.share_type,
             SUM(h.shares) AS shares,
             SUM(h.value_reported) AS value_reported,
             h.value_unit,
             SUM(h.value_usd) AS value_usd,
             BOOL_OR(h.suspect) AS suspect
      FROM institutional_holdings h
      INNER JOIN effective_reports er ON er.id = h.institutional_report_id
      GROUP BY h.cusip, h.title_of_class, h.share_type, COALESCE(h.put_call, ''), h.value_unit
      ORDER BY value_usd DESC NULLS LAST, value_reported DESC, h.cusip
      LIMIT :limit
    SQL
  end

  def position_changes(limit: 12)
    return [] unless latest_report

    PositionDiff.where(institutional_filer_id: @institutional_filer.id,
                       period_of_report: latest_report.period_of_report)
                .order(Arel.sql("ABS(value_usd_delta) DESC NULLS LAST, ABS(shares_delta) DESC, cusip"))
                .limit(limit)
                .as_json(except: %i[id institutional_filer_id institutional_report_id prior_institutional_report_id
                                     created_at updated_at])
  end

  private

  def select(sql, **binds)
    binds = binds.merge(institutional_filer_id: @institutional_filer.id)
    ApplicationRecord.connection.select_all(ApplicationRecord.sanitize_sql([ sql, binds ])).to_a
  end
end
