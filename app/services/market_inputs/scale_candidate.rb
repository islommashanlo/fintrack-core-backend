# frozen_string_literal: true

module MarketInputs
  # A policy-constrained source observation, never a verified scoring denominator.
  class ScaleCandidate
    Result = Data.define(:status, :reason, :observation_id, :issuer_cik, :market_cap, :currency, :measurement_basis,
      :candidate_count, :revision_groups, :evaluated_at, :policy_version, :policy_digest)

    def initialize(issuer_cik:, as_of:, policy: ScaleSourcePolicy.new)
      raise ArgumentError, "Invalid issuer CIK" unless issuer_cik.is_a?(String) && issuer_cik.match?(/\A[0-9]{10}\z/)
      raise ArgumentError, "Invalid evaluation time" unless as_of.is_a?(Time) || as_of.is_a?(ActiveSupport::TimeWithZone)
      raise ArgumentError, "Invalid scale source policy" unless policy.is_a?(ScaleSourcePolicy)

      @issuer_cik, @as_of, @policy = issuer_cik.dup.freeze, as_of.getutc.dup.freeze, policy
    end

    def call
      return result("source_policy_missing") if @policy.sources.empty?

      binds = { sources: @policy.sources, at: @as_of, cutoff: @as_of - @policy.maximum_age_seconds,
        cik: @issuer_cik, currency: @policy.currency, basis: @policy.measurement_basis }
      row = ApplicationRecord.connection.select_one(ApplicationRecord.sanitize_sql([ <<~SQL, binds ]))
        WITH known AS (
          SELECT * FROM issuer_scale_observations
          WHERE source IN (:sources) AND observed_at <= :at AND created_at <= :at
        ), related AS (
          SELECT DISTINCT source, source_record_id FROM known WHERE issuer_cik = :cik
        ), relevant AS (
          SELECT k.* FROM known k INNER JOIN related r USING (source, source_record_id)
        ), revisions AS (
          SELECT source, source_record_id FROM relevant
          GROUP BY source, source_record_id HAVING COUNT(*) > 1
        ), candidates AS (
          SELECT * FROM relevant WHERE issuer_cik = :cik AND currency = :currency AND measurement_basis = :basis
            AND effective_at >= :cutoff AND effective_at <= :at
        )
        SELECT COUNT(*) AS candidate_count, (SELECT COUNT(*) FROM revisions) AS revision_groups,
          CASE WHEN COUNT(*) = 1 THEN MIN(id) END AS observation_id,
          CASE WHEN COUNT(*) = 1 THEN MIN(market_cap) END AS market_cap
        FROM candidates
      SQL
      count, revisions = Integer(row.fetch("candidate_count")), Integer(row.fetch("revision_groups"))
      amount = BigDecimal(row.fetch("market_cap").to_s) if count == 1
      reason = if revisions.positive? then "unresolved_revisions"
      elsif count.zero? then "no_applicable_observation"
      elsif count > 1 then "multiple_applicable_observations"
      elsif !amount.finite? || !amount.positive? then "unusable_amount"
      end
      result(reason, count:, revisions:, row:, amount:)
    end

    private

    def result(reason, count: nil, revisions: nil, row: nil, amount: nil)
      selected = reason.nil?
      Result.new(status: selected ? "candidate" : "unavailable", reason:,
        observation_id: selected ? Integer(row.fetch("observation_id")) : nil,
        issuer_cik: selected ? @issuer_cik : nil, market_cap: selected ? amount : nil,
        currency: selected ? @policy.currency : nil, measurement_basis: selected ? @policy.measurement_basis : nil,
        candidate_count: count, revision_groups: revisions, evaluated_at: @as_of.getutc.iso8601(6),
        policy_version: ScaleSourcePolicy::VERSION, policy_digest: @policy.digest)
    end
  end
end
