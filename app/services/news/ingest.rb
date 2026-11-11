# frozen_string_literal: true

module News
  class Ingest
    class Conflict < StandardError; end
    MAX_ITEMS = 100

    def self.call(provider:, items:, observed_at: Time.current)
      new(provider:, items:, observed_at:).call
    end

    def initialize(provider:, items:, observed_at:)
      unless provider.is_a?(String) && provider.match?(/\A[a-z][a-z0-9_]{0,39}\z/) &&
             items.is_a?(Array) && items.size <= MAX_ITEMS && items.all? { |item| item.is_a?(Item) }
        raise Provider::InvalidResponse, "Expected a provider key and at most #{MAX_ITEMS} news items"
      end
      unless items.map(&:provider_item_id).uniq.size == items.size && items.none? { |item| item.published_at > observed_at }
        raise Provider::InvalidResponse, "Duplicate news identity or future publication timestamp"
      end
      @provider, @items, @observed_at = provider, items, observed_at
    end

    def call
      count = NewsItem.transaction do
        # Serialize this provider's writes only. No adapter call holds this lock.
        sql = NewsItem.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "news:#{@provider}" ])
        NewsItem.connection.execute(sql)
        @items.each { |item| persist(item) }
        @items.size
      end
      if AlertRule.active.where(event_type: "news").exists?
        Visibility.items(as_of: Time.current).where(provider: @provider, provider_item_id: @items.map(&:provider_item_id))
          .pluck(:id).each { |id| EvaluateNewsAlertsJob.perform_later(id) }
      end
      count
    end

    private

    def persist(item)
      record = NewsItem.find_by(provider: @provider, provider_item_id: item.provider_item_id)
      if record && !item.content.all? { |field, value| record.public_send(field) == value }
        raise Conflict, "Stored news content differs for this provider item"
      end
      record ||= NewsItem.create!(provider: @provider, provider_item_id: item.provider_item_id,
                                 **item.content, observed_at: @observed_at, suppression_reason: item.suppression_reason)
      item.entities.each do |entity|
        mention = record.news_mentions.find_or_initialize_by(**entity.identity)
        mention.observed_at ||= @observed_at
        mention.save!
      end
    end
  end
end
