# frozen_string_literal: true

# Read-only inventory of source assertions, never a certification or score gate.
class MarketInputReadiness
  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    { as_of: @now.utc.iso8601, status: "unverified", readiness_certified: false,
      requirements: ActivityMethodology.definition.fetch("score").fetch("market_input_requirements"),
      scale_observations: scale_observations, identity_evidence: identity_evidence, price_bars: price_bars }
  end

  private

  def scale_observations
    counts(<<~SQL)
      WITH recorded AS (SELECT * FROM issuer_scale_observations WHERE created_at <= :at),
      candidates AS (SELECT * FROM recorded WHERE effective_at <= :at AND observed_at <= :at),
      revisions AS (
        SELECT issuer_cik, source, source_record_id FROM candidates
        GROUP BY issuer_cik, source, source_record_id HAVING COUNT(*) > 1
      )
      SELECT (SELECT COUNT(*) FROM recorded) AS recorded_count,
        COUNT(*) AS candidate_count, COUNT(DISTINCT issuer_cik) AS issuer_count,
        COUNT(DISTINCT source) AS source_count, COUNT(*) FILTER (WHERE market_cap = 0) AS zero_amount_count,
        (SELECT COUNT(*) FROM revisions) AS multiple_revision_groups
      FROM candidates
    SQL
  end

  def identity_evidence
    counts(<<~SQL)
      WITH recorded AS (SELECT * FROM issuer_security_evidences WHERE created_at <= :at),
      candidates AS (
        SELECT * FROM recorded WHERE observed_at <= :at AND effective_from <= :at
          AND (effective_to IS NULL OR effective_to > :at)
      ), revisions AS (
        SELECT issuer_cik, security_id, source, source_record_id FROM candidates
        GROUP BY issuer_cik, security_id, source, source_record_id HAVING COUNT(*) > 1
      ), identifiers AS (
        SELECT security_figi FROM candidates GROUP BY security_figi HAVING COUNT(DISTINCT issuer_cik) > 1
      ), aliases AS (
        SELECT cusip FROM candidates WHERE cusip IS NOT NULL GROUP BY cusip HAVING COUNT(DISTINCT issuer_cik) > 1
      )
      SELECT (SELECT COUNT(*) FROM recorded) AS recorded_count,
        COUNT(*) AS candidate_count, COUNT(DISTINCT c.issuer_cik) AS issuer_count,
        COUNT(DISTINCT c.source) AS source_count,
        COUNT(*) FILTER (WHERE c.cusip IS NULL) AS missing_cusip_count,
        COUNT(*) FILTER (WHERE c.ticker IS NULL) AS missing_ticker_count,
        COUNT(*) FILTER (WHERE c.security_figi IS DISTINCT FROM s.figi) AS current_identifier_mismatch_count,
        (SELECT COUNT(*) FROM revisions) AS multiple_revision_groups,
        (SELECT COUNT(*) FROM identifiers) AS multi_issuer_figi_groups,
        (SELECT COUNT(*) FROM aliases) AS multi_issuer_cusip_groups
      FROM candidates c INNER JOIN securities s ON s.id = c.security_id
    SQL
  end

  def price_bars
    counts(<<~SQL)
      WITH recorded AS (SELECT * FROM prices_daily WHERE created_at <= :at)
      SELECT (SELECT COUNT(*) FROM recorded) AS recorded_count,
        COUNT(*) AS observed_bar_count, COUNT(DISTINCT p.price_series_id) AS series_count,
        COUNT(DISTINCT s.provider) AS source_count
      FROM recorded p INNER JOIN price_series s ON s.id = p.price_series_id
      WHERE p.observed_at <= :at AND p.session_date <= :date AND s.created_at <= :at
    SQL
  end

  def counts(sql)
    row = ApplicationRecord.connection.select_one(ApplicationRecord.sanitize_sql([ sql, { at: @now, date: @now.utc.to_date } ]))
    row.transform_values { |value| Integer(value) }
  end
end
