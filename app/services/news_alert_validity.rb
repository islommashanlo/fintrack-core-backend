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
    scope.reselect("1").to_sql
  end

  def self.apply(scope, as_of:)
    valid = snapshot_sources(as_of:).merge(NewsAlertMatcher.matches(as_of:))
      .where("snapshot.id = alert_deliveries.news_alert_snapshot_id AND snapshot.news_item_id = alert_deliveries.news_item_id AND rules.id = alert_deliveries.alert_rule_id")
    scope.where("alert_deliveries.news_alert_snapshot_id IS NULL OR EXISTS (#{valid.reselect('1').to_sql})")
  end
end
