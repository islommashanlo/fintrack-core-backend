# frozen_string_literal: true

require "digest"
require "json"

module MarketInputs
  class ScaleSourcePolicy
    VERSION = "scale-candidate-v1"
    attr_reader :sources, :currency, :measurement_basis, :maximum_age_seconds, :digest

    def initialize(sources: [], currency: nil, measurement_basis: nil, maximum_age_seconds: nil)
      unless sources.is_a?(Array) && sources.size <= 20 && sources.uniq.size == sources.size &&
          sources.all? { |source| source.is_a?(String) && source.match?(/\A[a-z][a-z0-9_]{0,39}\z/) }
        raise ArgumentError, "Invalid scale source allowlist"
      end
      if sources.empty?
        raise ArgumentError, "Scale settings require sources" unless [ currency, measurement_basis, maximum_age_seconds ].all?(&:nil?)
      elsif !currency.is_a?(String) || !currency.match?(/\A[A-Z]{3}\z/) ||
          !measurement_basis.is_a?(String) || measurement_basis.blank? || measurement_basis.length > 100 ||
          !maximum_age_seconds.is_a?(Integer) || !maximum_age_seconds.between?(1, 2**31 - 1)
        raise ArgumentError, "Invalid scale currency, basis or freshness policy"
      end
      @sources = sources.map { |source| source.dup.freeze }.sort.freeze
      @currency, @measurement_basis, @maximum_age_seconds = currency&.dup&.freeze, measurement_basis&.dup&.freeze, maximum_age_seconds
      @digest = Digest::SHA256.hexdigest(JSON.generate([ @sources, @currency, @measurement_basis, @maximum_age_seconds ])).freeze
      freeze
    end
  end
end
