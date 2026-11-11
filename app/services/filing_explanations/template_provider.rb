# frozen_string_literal: true

module FilingExplanations
  class TemplateProvider
    KEY = "template-v1"

    def cache_key
      KEY
    end

    def generate(system_prompt:, facts:)
      Provider::Result.new(model: KEY, fact_ids: facts.map { |fact| fact.fetch(:id) })
    end
  end
end
