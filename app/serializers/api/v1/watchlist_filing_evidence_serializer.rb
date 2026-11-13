# frozen_string_literal: true

module Api
  module V1
    class WatchlistFilingEvidenceSerializer
      def initialize(ids:, channel:)
        @summaries = WatchlistFilingMembership.summaries(ids, channel:).merge(WatchlistNewsMembership.summaries(ids, channel:))
      end

      def render(id)
        evidence = @summaries.fetch(id)
        entities = evidence.fetch("entities").map do |entity|
          { follow_id: entity.fetch("follow_id"), type: WatchlistTarget::API_TYPES.fetch(entity.fetch("target_type")),
            key: entity.fetch("key"), followed_at: entity.fetch("followed_at") }
        end
        { matched_entities: entities, matched_entities_total_count: evidence.fetch("total_count"),
          matched_entities_truncated: evidence.fetch("total_count") > entities.length }
      end
    end
  end
end
