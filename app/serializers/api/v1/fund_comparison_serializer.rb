# frozen_string_literal: true

module Api
  module V1
    class FundComparisonSerializer
      def initialize(states:, as_of:)
        @as_of = as_of
        @states = states.index_by { |row| row.fetch("cik") }
        ids = states.flat_map { |row| Array(row["current_report_ids"]) + Array(row["prior_report_ids"]) }
        @reports = InstitutionalReport.where(id: ids).includes(:filing).index_by(&:id)
      end

      def fund(row)
        provenance(row["primary_report_id"]).merge(row.slice("cik", "name", "current_available", "prior_available",
          "current_report_present", "prior_report_present", "current_report_suspect", "prior_report_suspect",
          "position_count", "excluded_current_rows", "excluded_prior_rows"),
          current_sources: sources(row["current_report_ids"]), prior_sources: sources(row["prior_report_ids"]))
      end

      def overlap(row)
        provenance(row["primary_report_id"]).merge(row.except("primary_report_id"),
          sources: [ row.fetch("left_cik"), row.fetch("right_cik") ].flat_map do |cik|
            state = @states.fetch(cik)
            sources(state["current_report_ids"]) + sources(state["prior_report_ids"])
          end)
      end

      def position(row)
        entries = row.fetch("funds")
        entries = JSON.parse(entries) if entries.is_a?(String)
        provenance(row["primary_report_id"]).merge(row.slice("cusip", "put_call", "share_type", "issuer_name", "holder_count", "shared_by_all", "differing_moves"),
          funds: entries.map do |entry|
            state = @states.fetch(entry.fetch("cik"))
            provenance(state["primary_report_id"]).merge(entry, current_available: state.fetch("current_available"),
              prior_available: state.fetch("prior_available"), current_sources: sources(state["current_report_ids"]),
              prior_sources: sources(state["prior_report_ids"]))
          end)
      end

      private

      def sources(ids) = Array(ids).map { |id| provenance(id) }

      def provenance(id)
        return FilingProvenance.render(@reports.fetch(id).filing, as_of: @as_of) if id

        { accession: nil, sec_url: nil, form_type: nil, filed_at: nil, accepted_at: nil, ingested_at: nil, data_age_days: nil }
      end
    end
  end
end
