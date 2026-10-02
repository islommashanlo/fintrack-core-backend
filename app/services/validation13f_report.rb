# frozen_string_literal: true

# SQL-backed health checks for the institutional 13F ingestion pipeline.
class Validation13fReport
  Check = Data.define(:level, :title, :detail)

  def initialize
    @checks = [
      volume, missing_archives, cover_entry_mismatches, cover_value_mismatches,
      malformed_cusips, non_positive_shares, unknown_units, unit_jumps,
      unresolved_amendments, unresolved_notices, parse_failures, mapping_coverage, diff_coverage
    ]
  end

  def checks
    @checks
  end

  def failed?
    checks.any? { |check| check.level == :fail }
  end

  private

  def check(level, title, detail = nil)
    Check.new(level:, title:, detail:)
  end

  def reports
    InstitutionalReport.where(status: "parsed")
  end

  def volume
    check(:info, "#{InstitutionalReport.count} institutional reports (#{reports.count} parsed, " \
                 "#{InstitutionalReport.where(status: 'pending').count} pending, " \
                 "#{InstitutionalReport.where(status: 'failed').count} failed, " \
                 "#{InstitutionalReport.where(status: 'skipped').count} skipped); " \
                 "#{InstitutionalHolding.count} holding rows")
  end

  def missing_archives
    cover_count = reports.where(cover_raw_path: nil).count
    information_count = reports.where.not(submission_type: "13F-NT").where(information_raw_path: nil).count
    total = cover_count + information_count
    return check(:pass, "Every parsed 13F report has its required XML archive paths") if total.zero?

    check(:fail, "#{total} parsed 13F reports are missing required XML archive paths",
          "#{cover_count} cover paths and #{information_count} information-table paths are missing.")
  end

  def cover_entry_mismatches
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM institutional_reports r
      WHERE r.status = 'parsed'
        AND r.table_entry_total IS NOT NULL
        AND r.submission_type <> '13F-NT'
        AND r.table_entry_total <> (
          SELECT COUNT(*) FROM institutional_holdings h WHERE h.institutional_report_id = r.id
        )
    SQL
    return check(:pass, "Cover entry totals match parsed 13F rows") if count.zero?

    check(:warn, "#{count} 13F reports have cover entry-count mismatches",
          "The cover total and parsed table are both retained; inspect the report before using aggregates.")
  end

  def cover_value_mismatches
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM institutional_reports r
      WHERE r.status = 'parsed'
        AND r.table_value_total IS NOT NULL
        AND r.submission_type <> '13F-NT'
        AND r.table_value_total <> (
          SELECT COALESCE(SUM(h.value_reported), 0)
          FROM institutional_holdings h WHERE h.institutional_report_id = r.id
        )
    SQL
    return check(:pass, "Cover value totals match reported holding values") if count.zero?

    check(:warn, "#{count} 13F reports have cover value-total mismatches",
          "Reported values were not corrected; check units, omitted holdings and amendments.")
  end

  def malformed_cusips
    count = InstitutionalHolding.where("cusip IS NULL OR cusip !~ ?", "^[0-9A-Z]{9}$").count
    return check(:pass, "All 13F CUSIPs have the expected nine-character shape") if count.zero?

    check(:warn, "#{count} 13F holdings have malformed CUSIP shapes",
          "The CUSIPs remain as reported and are excluded from enrichment until reviewed.")
  end

  def non_positive_shares
    count = InstitutionalHolding.where("shares <= 0").count
    return check(:pass, "All 13F holding share counts are positive") if count.zero?

    check(:warn, "#{count} 13F holdings have zero or negative shares",
          "The share counts remain as reported; this is an integrity flag, not a correction.")
  end

  def unknown_units
    count = InstitutionalHolding.where.not(value_unit: %w[whole_dollars thousands]).count
    return check(:pass, "All 13F holding value units are known") if count.zero?

    check(:warn, "#{count} 13F holdings have unknown value units",
          "Their value_usd is NULL until the empirically verified unit policy is configured.")
  end

  def unit_jumps
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM (
        SELECT r.institutional_filer_id, r.period_of_report, r.table_value_total,
               LAG(r.table_value_total) OVER (
                 PARTITION BY r.institutional_filer_id ORDER BY r.period_of_report, r.filed_at, r.id
               ) AS previous_total
        FROM institutional_reports r
        WHERE r.status = 'parsed' AND r.table_value_total > 0
      ) totals
      WHERE totals.previous_total > 0
        AND (totals.table_value_total / totals.previous_total BETWEEN 900 AND 1100
             OR totals.previous_total / totals.table_value_total BETWEEN 900 AND 1100)
    SQL
    return check(:pass, "No institutional reported total jumps by about 1000x") if count.zero?

    check(:warn, "#{count} institutional quarter transitions jump by about 1000x",
          "Review value units and the filed-at timeline; reported values were left unchanged.")
  end

  def unresolved_amendments
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM institutional_reports a
      WHERE a.status = 'parsed'
        AND a.amendment_type IN ('RESTATEMENT', 'NEW HOLDINGS')
        AND NOT EXISTS (
          SELECT 1 FROM institutional_reports o
          WHERE o.institutional_filer_id = a.institutional_filer_id
            AND o.period_of_report = a.period_of_report
            AND o.status = 'parsed'
            AND o.amendment_type IS NULL
        )
    SQL
    return check(:pass, "Every parsed 13F amendment has a resolvable original") if count.zero?

    check(:warn, "#{count} 13F amendments have no resolvable original",
          "They remain stored, but effective holdings cannot include them until the base report is available.")
  end

  def unresolved_notices
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM institutional_reports r
      INNER JOIN filings f ON f.id = r.filing_id
      LEFT JOIN institutional_filers i ON i.id = r.institutional_filer_id
      WHERE r.status = 'parsed'
        AND r.submission_type = '13F-NT'
        AND (i.cik IS NULL OR i.name IS NULL OR i.cik <> f.cik)
    SQL
    return check(:pass, "Every parsed 13F-NT has a resolved reporting manager") if count.zero?

    check(:fail, "#{count} 13F-NT reports have no resolvable reporting manager",
          "Resolve the reporting CIK before using the notice in effective holdings queries.")
  end

  def parse_failures
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM parse_failures p
      WHERE EXISTS (
        SELECT 1 FROM filings f
        WHERE f.accession_no = p.accession_no
          AND f.form_type IN ('13F-HR', '13F-HR/A', '13F-NT')
      )
        AND p.resolved_at IS NULL
    SQL
    return check(:pass, "No unresolved 13F parse failures") if count.zero?

    check(:fail, "#{count} unresolved 13F parse failures",
          "Deterministic failures need review; transient failures are retried by ParseForm13fJob.")
  end

  def mapping_coverage
    total = scalar(<<~SQL)
      SELECT COUNT(DISTINCT cusip)
      FROM institutional_holdings
      WHERE cusip ~ '^[0-9A-Z]{9}$'
    SQL
    return check(:info, "No valid CUSIPs are ready for enrichment") if total.zero?

    latest = <<~SQL
      SELECT DISTINCT ON (cusip) cusip, status
      FROM cusip_security_mappings
      WHERE source = 'openfigi'
      ORDER BY cusip, last_checked_at DESC, id DESC
    SQL
    mapped = scalar("SELECT COUNT(*) FROM (#{latest}) current WHERE current.status = 'mapped'")
    ambiguous = scalar("SELECT COUNT(*) FROM (#{latest}) current WHERE current.status = 'ambiguous'")
    return check(:pass, "All valid 13F CUSIPs have an unambiguous OpenFIGI mapping") if mapped == total

    check(:warn, "#{total - mapped} of #{total} valid 13F CUSIPs lack an unambiguous mapping",
          "#{ambiguous} are ambiguous; unmapped and stale results remain stored for review. " \
          "Run `rake enrich:cusips` to inspect the request count before enrichment.")
  end

  def diff_coverage
    count = scalar(<<~SQL)
      SELECT COUNT(*)
      FROM institutional_reports current_report
      WHERE current_report.status = 'parsed'
        AND (current_report.amendment_type IS NULL OR current_report.amendment_type = 'RESTATEMENT')
        AND EXISTS (
          SELECT 1
          FROM institutional_reports prior_report
          WHERE prior_report.institutional_filer_id = current_report.institutional_filer_id
            AND prior_report.period_of_report < current_report.period_of_report
            AND prior_report.status = 'parsed'
            AND (prior_report.amendment_type IS NULL OR prior_report.amendment_type = 'RESTATEMENT')
        )
        AND NOT EXISTS (
          SELECT 1
          FROM position_diffs d
          WHERE d.institutional_filer_id = current_report.institutional_filer_id
            AND d.period_of_report = current_report.period_of_report
        )
    SQL
    return check(:pass, "Every multi-quarter 13F filer has materialized position diffs") if count.zero?

    check(:warn, "#{count} multi-quarter 13F reports have no materialized position diffs",
          "Run `rake position_diffs:materialize[FILER_ID,PERIOD]` for the affected filer and period.")
  end

  def scalar(sql)
    InstitutionalReport.connection.select_value(sql).to_i
  end
end
