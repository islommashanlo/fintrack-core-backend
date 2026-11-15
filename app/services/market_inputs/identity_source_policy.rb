# frozen_string_literal: true

require "digest"
require "json"

module MarketInputs
  # Operator-owned policy input, never a request-controlled claim of authority.
  class IdentitySourcePolicy
    VERSION = "identity-candidate-v1"
    attr_reader :sources, :digest

    def initialize(sources: [])
      unless sources.is_a?(Array) && sources.size <= 20 && sources.uniq.size == sources.size &&
          sources.all? { |source| source.is_a?(String) && source.match?(/\A[a-z][a-z0-9_]{0,39}\z/) }
        raise ArgumentError, "Invalid identity source allowlist"
      end
      @sources = sources.map { |source| source.dup.freeze }.sort.freeze
      @digest = Digest::SHA256.hexdigest(JSON.generate(@sources)).freeze
      freeze
    end
  end
end
