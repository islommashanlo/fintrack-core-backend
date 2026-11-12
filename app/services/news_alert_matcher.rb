# frozen_string_literal: true

class NewsAlertMatcher
  ITEM_FIELDS = %w[provider provider_item_id source title url kind published_at].freeze
  MENTION_FIELDS = %w[entity_type entity_id role].freeze

  def self.matches(as_of:, channel: "email")
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)
    News::Visibility.mentions(as_of:).joins(:news_item).merge(News::Visibility.items(as_of:))
      .joins("INNER JOIN follows ON (#{News::Visibility.follow_match(as_of:)})")
      .joins("INNER JOIN alert_rules rules ON rules.follow_id = follows.id INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id")
      .where("rules.active AND rules.event_type = 'news' AND follows.removed_at IS NULL AND settings.archived_at IS NULL")
      .where("rules.channel = ?", channel)
      .where("news_items.published_at >= settings.enabled_at AND news_items.published_at >= follows.followed_at")
      .where("settings.conditions->'kinds' IS NULL OR settings.conditions->'kinds' @> jsonb_build_array(news_items.kind)")
      .where("settings.conditions->'providers' IS NULL OR settings.conditions->'providers' @> jsonb_build_array(news_items.provider)")
      .where("settings.conditions->>'source' IS NULL OR settings.conditions->>'source' = news_items.source")
  end

  def self.call(item, as_of: Time.current, channel: "email")
    return [] unless item && AlertRule.active.where(event_type: "news", channel:).exists?

    rows = matches(as_of:, channel:).where(news_item_id: item.id).select(
      "rules.id AS rule_id", "settings.frequency", "settings.revision AS rule_revision",
      "news_items.id AS news_item_id", "news_mentions.id AS news_mention_id",
      "news_items.observed_at AS item_observed_at", "news_mentions.observed_at AS mention_observed_at",
      "COALESCE(news_filer.cik, news_fund.cik) AS cik",
      *ITEM_FIELDS.map { |field| "news_items.#{field}" }, *MENTION_FIELDS.map { |field| "news_mentions.#{field}" }
    ).map(&:attributes)
    return [] if rows.empty?

    fields = ITEM_FIELDS + MENTION_FIELDS + %w[news_item_id news_mention_id item_observed_at mention_observed_at cik]
    snapshots = rows.map { |row| row.slice(*fields).merge("observed_at" => as_of) }.uniq { |row| row.fetch("news_mention_id") }
    NewsAlertSnapshot.insert_all(snapshots, unique_by: :index_news_alert_snapshots_on_news_mention_id)
    ids = NewsAlertSnapshot.where(news_mention_id: rows.map { |row| row.fetch("news_mention_id") }).pluck(:news_mention_id, :id).to_h
    rows.map { |row| row.merge("news_alert_snapshot_id" => ids.fetch(row.fetch("news_mention_id"))) }
  end
end
