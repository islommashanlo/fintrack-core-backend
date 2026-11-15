# frozen_string_literal: true

module MarketInputs
  # Selects one stored assertion under an explicit policy; it does not verify it.
  class IdentityCandidate
    Result = Data.define(:status, :reason, :evidence_id, :issuer_cik, :security_figi,
      :candidate_count, :revision_groups, :evaluated_at, :policy_version, :policy_digest)

    def initialize(cusip:, as_of:, policy: IdentitySourcePolicy.new)
      raise ArgumentError, "Invalid CUSIP" unless cusip.is_a?(String) && cusip.match?(/\A[0-9A-Z]{9}\z/)
      raise ArgumentError, "Invalid evaluation time" unless as_of.is_a?(Time) || as_of.is_a?(ActiveSupport::TimeWithZone)
      raise ArgumentError, "Invalid identity source policy" unless policy.is_a?(IdentitySourcePolicy)

      @cusip, @as_of, @policy = cusip.dup.freeze, as_of.getutc.dup.freeze, policy
    end

    def call
      return result("source_policy_missing") if @policy.sources.empty?

      row = ApplicationRecord.connection.select_one(ApplicationRecord.sanitize_sql([ <<~SQL, sources: @policy.sources, at: @as_of, cusip: @cusip ]))
        WITH known AS (
          SELECT * FROM issuer_security_evidences
          WHERE source IN (:sources) AND observed_at <= :at AND created_at <= :at
        ), related AS (
          SELECT DISTINCT source, source_record_id FROM known WHERE cusip = :cusip
        ), relevant AS (
          SELECT k.* FROM known k INNER JOIN related r USING (source, source_record_id)
        ), revisions AS (
          SELECT source, source_record_id FROM relevant
          GROUP BY source, source_record_id HAVING COUNT(*) > 1
        ), candidates AS (
          SELECT * FROM relevant WHERE cusip = :cusip AND effective_from <= :at
            AND (effective_to IS NULL OR effective_to > :at)
        )
        SELECT COUNT(*) AS candidate_count, (SELECT COUNT(*) FROM revisions) AS revision_groups,
          CASE WHEN COUNT(*) = 1 THEN MIN(id) END AS evidence_id,
          CASE WHEN COUNT(*) = 1 THEN MIN(issuer_cik) END AS issuer_cik,
          CASE WHEN COUNT(*) = 1 THEN MIN(security_figi) END AS security_figi
        FROM candidates
      SQL
      count, revisions = Integer(row.fetch("candidate_count")), Integer(row.fetch("revision_groups"))
      reason = if revisions.positive? then "unresolved_revisions"
      elsif count.zero? then "no_applicable_assertion"
      elsif count > 1 then "multiple_applicable_assertions"
      end
      result(reason, count:, revisions:, row:)
    end

    private

    def result(reason, count: nil, revisions: nil, row: nil)
      selected = reason.nil?
      Result.new(status: selected ? "candidate" : "unavailable", reason:,
        evidence_id: selected ? Integer(row.fetch("evidence_id")) : nil,
        issuer_cik: selected ? row.fetch("issuer_cik") : nil, security_figi: selected ? row.fetch("security_figi") : nil,
        candidate_count: count, revision_groups: revisions, evaluated_at: @as_of.getutc.iso8601(6),
        policy_version: IdentitySourcePolicy::VERSION, policy_digest: @policy.digest)
    end
  end
end
