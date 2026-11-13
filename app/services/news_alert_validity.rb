# frozen_string_literal: true

class NewsAlertValidity
  def self.visible_ids(ids, as_of:)
    return [] if ids.empty?

    snapshot_sources(as_of:).where("snapshot.id IN (?)", ids).pluck(Arel.sql("snapshot.id"))
  end

  def self.snapshot_sources(as_of:)
    scope = News::Visibility.mentions(as_of:).joins(:news_item).merge(News::Visibility.items(as_of:))
      .joins("INNER JOIN news_alert_snapshots snapshot ON snapshot.news_mention_id = news_mentions.id AND snapshot.news_item_id = news_items.id")
    equalities = NewsAlertMatcher::ITEM_FIELDS.map { |field| "snapshot.#{field} = news_items.#{field}" } +
      NewsAlertMatcher::MENTION_FIELDS.map { |field| "snapshot.#{field} = news_mentions.#{field}" }
    scope.where(equalities.join(" AND "))
      .where("snapshot.item_observed_at = news_items.observed_at AND snapshot.mention_observed_at = news_mentions.observed_at AND snapshot.cik = COALESCE(news_filer.cik, news_fund.cik)")
      .where("snapshot.observed_at <= ?", as_of)
  end

  def self.notification_sources(as_of:, max_filing_id: nil, max_news_item_id: nil, max_news_mention_id: nil)
    scope = snapshot_sources(as_of:)
      .joins("INNER JOIN follows ON (#{News::Visibility.follow_match(as_of:, max_filing_id:)})")
      .joins("INNER JOIN alert_rules source_rule ON source_rule.follow_id = follows.id")
      .where("source_rule.id = in_app_notifications.alert_rule_id AND snapshot.id = in_app_notifications.news_alert_snapshot_id AND snapshot.news_item_id = in_app_notifications.news_item_id")
    scope = scope.where("news_items.id <= ?", max_news_item_id) if max_news_item_id
    scope = scope.where("news_mentions.id <= ?", max_news_mention_id) if max_news_mention_id
    follow_sql = scope.reselect("1").to_sql
    "#{follow_sql} UNION ALL #{watchlist_sources(channel: 'in_app', as_of:, max_filing_id:, max_news_item_id:, max_news_mention_id:)}"
  end

  def self.apply(scope, as_of:)
    valid = snapshot_sources(as_of:).merge(NewsAlertMatcher.matches(as_of:))
      .where("snapshot.id = alert_deliveries.news_alert_snapshot_id AND snapshot.news_item_id = alert_deliveries.news_item_id AND rules.id = alert_deliveries.alert_rule_id")
    scope.where("alert_deliveries.news_alert_snapshot_id IS NULL OR EXISTS (#{valid.reselect('1').to_sql}) OR EXISTS (#{watchlist_sources(channel: 'email', as_of:)})")
  end

  def self.watchlist_sources(channel:, as_of:, pending: false, max_filing_id: nil, max_news_item_id: nil, max_news_mention_id: nil)
    column, table = WatchlistNewsMembership::DESTINATIONS.fetch(channel)
    representative = snapshot_sources(as_of:)
      .where("snapshot.id = #{table}.news_alert_snapshot_id AND snapshot.news_item_id = #{table}.news_item_id")
    representative = representative.where("news_items.id <= ?", max_news_item_id) if max_news_item_id
    representative = representative.where("news_mentions.id <= ?", max_news_mention_id) if max_news_mention_id
    scope = snapshot_sources(as_of:)
      .joins("INNER JOIN watchlist_news_memberships follows ON follows.news_alert_snapshot_id = snapshot.id AND follows.news_item_id = snapshot.news_item_id")
      .joins("INNER JOIN alert_rules source_rule ON source_rule.id = follows.alert_rule_id AND source_rule.user_id = follows.user_id")
      .where("source_rule.scope = 'watchlist' AND source_rule.channel = ?", channel)
      .where("follows.#{column} = #{table}.id AND follows.alert_rule_id = #{table}.alert_rule_id AND snapshot.news_item_id = #{table}.news_item_id")
      .where(News::Visibility.follow_match(as_of:, max_filing_id:))
      .where("EXISTS (#{representative.reselect('1').to_sql})")
    scope = scope.where("news_items.id <= ?", max_news_item_id) if max_news_item_id
    scope = scope.where("news_mentions.id <= ?", max_news_mention_id) if max_news_mention_id
    if pending
      scope = scope.joins("INNER JOIN follows live ON live.id = follows.follow_id AND live.user_id = follows.user_id")
        .joins("INNER JOIN alert_rule_settings witness_settings ON witness_settings.alert_rule_id = follows.alert_rule_id")
        .where("snapshot.published_at >= live.followed_at AND snapshot.published_at >= witness_settings.enabled_at")
        .where("live.removed_at IS NULL AND live.followed_at = follows.followed_at AND live.target_type = follows.target_type AND live.target_key = follows.target_key")
    end
    scope.reselect("1").to_sql
  end
end
