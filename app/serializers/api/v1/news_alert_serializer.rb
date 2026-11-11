# frozen_string_literal: true

module Api
  module V1
    class NewsAlertSerializer
      def initialize(snapshots:, as_of:)
        @visible_ids = NewsAlertValidity.visible_ids(snapshots.map(&:id), as_of:)
      end

      def render(snapshot)
        return unless snapshot && @visible_ids.include?(snapshot.id)

        { id: snapshot.id, news_item_id: snapshot.news_item_id, provider: snapshot.provider,
          provider_item_id: snapshot.provider_item_id, source: snapshot.source, title: snapshot.title,
          url: snapshot.url, kind: snapshot.kind, published_at: snapshot.published_at,
          item_observed_at: snapshot.item_observed_at, mention_observed_at: snapshot.mention_observed_at,
          observed_at: snapshot.observed_at, entity: { entity_type: snapshot.role, cik: snapshot.cik } }
      end
    end
  end
end
