# frozen_string_literal: true

# Aggregates the latest materialized institutional quarter into a public whale
# flow signal. Suspect value deltas remain visible through the flag but do not
# contribute to the net dollar flow.
class InstitutionalFlow
  def initialize(as_of: Time.current)
    @as_of = as_of
  end

  def top_moves(limit: 8)
    ApplicationRecord.connection.select_all(
      ApplicationRecord.sanitize_sql([ sql, { as_of: @as_of, limit: } ])
    ).to_a
  end

  private

  def sql
    <<~SQL
      WITH available_period AS (
        SELECT MAX(d.period_of_report) AS period_of_report
        FROM position_diffs d
        INNER JOIN institutional_reports r ON r.id = d.institutional_report_id
        WHERE r.status = 'parsed'
          AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
      )
      SELECT d.cusip,
             MIN(d.name_of_issuer) AS name_of_issuer,
             MIN(d.title_of_class) AS title_of_class,
             d.period_of_report,
             SUM(d.value_usd_delta) FILTER (WHERE NOT d.current_suspect AND NOT d.prior_suspect) AS net_value_usd_delta,
             SUM(d.shares_delta) AS net_shares_delta,
             COUNT(*) AS moves,
             COUNT(DISTINCT d.institutional_filer_id) AS institutions,
             BOOL_OR(d.current_suspect OR d.prior_suspect) AS suspect
      FROM position_diffs d
      INNER JOIN institutional_reports r ON r.id = d.institutional_report_id
      INNER JOIN available_period p ON p.period_of_report = d.period_of_report
      WHERE r.status = 'parsed'
        AND (r.filed_at IS NULL OR r.filed_at <= :as_of)
      GROUP BY d.cusip, d.period_of_report
      HAVING SUM(d.value_usd_delta) FILTER (WHERE NOT d.current_suspect AND NOT d.prior_suspect) IS NOT NULL
      ORDER BY ABS(SUM(d.value_usd_delta) FILTER (WHERE NOT d.current_suspect AND NOT d.prior_suspect)) DESC,
               COUNT(DISTINCT d.institutional_filer_id) DESC, d.cusip
      LIMIT :limit
    SQL
  end
end
