# frozen_string_literal: true

module MarketInputs
  class PreviewPolicy
    Result = Data.define(:identity_policy, :scale_policy)

    def self.load
      definition = YAML.safe_load_file(Rails.root.join("config/market_input_preview.yml"))
      unless definition.is_a?(Hash) && definition.keys.sort == %w[identity scale] &&
          definition["identity"].is_a?(Hash) && definition["identity"].keys == [ "sources" ] &&
          definition["scale"].is_a?(Hash) && definition["scale"].keys.sort == %w[currency maximum_age_seconds measurement_basis sources]
        raise ArgumentError, "Invalid operator preview policy"
      end
      Result.new(identity_policy: IdentitySourcePolicy.new(sources: definition.fetch("identity").fetch("sources")),
        scale_policy: ScaleSourcePolicy.new(**definition.fetch("scale").symbolize_keys))
    end
  end
end
