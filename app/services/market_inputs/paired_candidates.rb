# frozen_string_literal: true

module MarketInputs
  # Diagnostic composition only: even a matching pair remains unverified.
  class PairedCandidates
    Result = Data.define(:status, :reason, :readiness_certified, :evaluated_at, :identity, :scale, :scale_attempted, :policies)

    def initialize(cusip:, as_of:, identity_policy: IdentitySourcePolicy.new, scale_policy: ScaleSourcePolicy.new)
      raise ArgumentError, "Invalid scale source policy" unless scale_policy.is_a?(ScaleSourcePolicy)

      @identity_selector = IdentityCandidate.new(cusip:, as_of:, policy: identity_policy)
      @as_of = as_of.getutc.dup.freeze
      @evaluated_at = @as_of.iso8601(6).freeze
      @scale_policy = scale_policy
      @policies = {
        identity: { version: IdentitySourcePolicy::VERSION, digest: identity_policy.digest }.freeze,
        scale: { version: ScaleSourcePolicy::VERSION, digest: scale_policy.digest }.freeze
      }.freeze
    end

    def call
      identity = @identity_selector.call
      reason = if !matching_context?(identity, **@policies.fetch(:identity)) then "identity_context_mismatch"
      elsif identity.status != "candidate" then "identity_unavailable"
      end
      unless reason
        scale = ScaleCandidate.new(issuer_cik: identity.issuer_cik, as_of: @as_of, policy: @scale_policy).call
        reason = if !matching_context?(scale, **@policies.fetch(:scale)) then "scale_context_mismatch"
        elsif scale.status != "candidate" then "scale_unavailable"
        elsif scale.issuer_cik != identity.issuer_cik || scale.currency != @scale_policy.currency ||
            scale.measurement_basis != @scale_policy.measurement_basis then "scale_context_mismatch"
        end
      end
      Result.new(status: reason ? "unavailable" : "paired_candidate", reason:, readiness_certified: false,
        evaluated_at: @evaluated_at, identity:, scale:, scale_attempted: !scale.nil?, policies: @policies)
    end

    private

    def matching_context?(result, version:, digest:)
      result.evaluated_at == @evaluated_at && result.policy_version == version && result.policy_digest == digest
    end
  end
end
