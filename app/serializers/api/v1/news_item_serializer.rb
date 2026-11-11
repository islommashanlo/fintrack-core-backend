# frozen_string_literal: true

module Api
  module V1
    class NewsItemSerializer
      MENTION_LIMIT = 20

      def initialize(records:, mentions:)
        @mentions = {}
        return if records.empty?

        ranked = mentions.where(news_item_id: records.map(&:id)).select(
          "news_mentions.*", "COALESCE(news_filer.cik, news_fund.cik) AS news_cik",
          "ROW_NUMBER() OVER (PARTITION BY news_item_id ORDER BY role, entity_type, entity_id, news_mentions.id) AS news_rank",
          "COUNT(*) OVER (PARTITION BY news_item_id) AS news_count"
        )
        @mentions = CursorPage.sql_rows("SELECT * FROM (#{ranked.to_sql}) ranked WHERE news_rank <= #{MENTION_LIMIT} ORDER BY news_item_id, news_rank")
          .group_by { |row| row.fetch("news_item_id") }
      end

      def render(item)
        rows = @mentions.fetch(item.id, [])
        count = rows.first&.fetch("news_count") || 0
        {
          id: item.id, provider: item.provider, provider_item_id: item.provider_item_id,
          source: item.source, title: item.title, url: item.url, kind: item.kind,
          published_at: item.published_at, observed_at: item.observed_at,
          mentions: rows.map { |row| { entity_type: row.fetch("role"), cik: row.fetch("news_cik"), observed_at: row.fetch("observed_at") } },
          mentions_meta: { total_count: count, shown: rows.size, limit: MENTION_LIMIT, truncated: count > rows.size }
        }
      end
    end
  end
end
