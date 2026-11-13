# frozen_string_literal: true

module Api
  module V1
    class FundTurnoverSummarySerializer
      PROVENANCE = %i[accession form_type sec_url filed_at accepted_at ingested_at data_age_days].freeze
      FIELDS = (PROVENANCE + %i[period_of_report prior_period_of_report status unavailable_reason reported_allocation_turnover_percent]).freeze

      def self.render(result)
        data, meta = result.values_at(:data, :meta)
        current, prior = data.values_at(:current_portfolio, :prior_portfolio)
        data.slice(*FIELDS).merge(methodology_version: meta.fetch(:methodology_version), baseline_policy: meta.fetch(:baseline_policy),
          current_complete: current.fetch("complete"), prior_complete: prior.fetch("complete"),
          current_source_scope: current.fetch("source_scope"), prior_source_scope: prior.fetch("source_scope"),
          current_sources: current.fetch("sources"), prior_sources: prior.fetch("sources"))
      end

      def self.history_restricted(period:)
        FIELDS.index_with { nil }.merge(period_of_report: period, status: "unavailable", unavailable_reason: "history_restricted",
          methodology_version: ActivityMethodology.definition.fetch("reported_allocation_turnover").fetch("version"),
          baseline_policy: "adjacent_calendar_quarter", current_complete: nil, prior_complete: nil,
          current_source_scope: nil, prior_source_scope: nil, current_sources: [], prior_sources: [])
      end
    end
  end
end
