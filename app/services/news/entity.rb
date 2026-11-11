# frozen_string_literal: true

module News
  Entity = Data.define(:role, :id) do
    def initialize(role:, id:)
      unless %w[issuer fund person].include?(role) && id.is_a?(Integer) && id.positive?
        raise Provider::InvalidResponse, "Expected a canonical news entity role and positive record ID"
      end

      super(role: role.dup.freeze, id:)
    end

    def entity_type
      role == "fund" ? "InstitutionalFiler" : "Filer"
    end

    def identity
      { entity_type:, entity_id: id, role: }
    end
  end
end
