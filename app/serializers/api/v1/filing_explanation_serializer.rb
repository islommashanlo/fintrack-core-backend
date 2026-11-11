# frozen_string_literal: true

module Api
  module V1
    class FilingExplanationSerializer
      def self.render(explanation, as_of: Time.current)
        filing = explanation.filing
        FilingProvenance.render(filing, as_of:).merge(
          period_of_report: filing.period_of_report,
          body: explanation.body,
          model: explanation.model,
          prompt_version: explanation.prompt_version,
          source_digest: explanation.source_digest,
          generation_method: explanation.generation_method,
          generated_at: explanation.generated_at,
          coverage: explanation.coverage,
          source_url: filing.sec_url,
          disclaimer: FilingsIntel::DISCLAIMER
        )
      end
    end
  end
end
