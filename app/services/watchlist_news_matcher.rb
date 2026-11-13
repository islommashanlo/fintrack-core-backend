# frozen_string_literal: true

class WatchlistNewsMatcher
  FIELDS = { rule_id: "bigint", user_id: "bigint", frequency: "varchar", rule_revision: "integer",
    news_item_id: "bigint", news_alert_snapshot_id: "bigint", follow_id: "bigint",
    followed_at: "timestamp", target_type: "varchar", target_key: "varchar", published_at: "timestamp" }.freeze

  def self.call(item, channel:, as_of: Time.current)
    matches = NewsAlertMatcher.call(item, channel:, as_of:, scope: "watchlist")
    return if matches.empty?

    connection = ApplicationRecord.connection
    rows = matches.map { |row| "(#{FIELDS.map { |key, type| "#{connection.quote(row.fetch(key.to_s))}::#{type}" }.join(', ')})" }.join(", ")
    source = "SELECT * FROM (VALUES #{rows}) AS matched(#{FIELDS.keys.join(', ')})"
    valid = NewsAlertValidity.snapshot_sources(as_of:)
      .where("snapshot.id = matched.news_alert_snapshot_id AND snapshot.news_item_id = matched.news_item_id")
      .where(News::Visibility.follow_match(as_of:)).reselect("1").to_sql
    columns, extra, conflict, destination = if channel == "email"
      [ "status", "'pending'", "news_item_id IS NOT NULL", "alert_delivery_id" ]
    else
      [ "time_zone, available_at", <<~SQL.squish, "event_type = 'news'", "in_app_notification_id" ]
        CASE WHEN frequency = 'daily_digest' THEN time_zone END,
        CASE WHEN frequency = 'instant' THEN :now::timestamp ELSE
          ((date_trunc('day', :now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone) + interval '7 hours'
            + CASE WHEN (:now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone)::time >= time '07:00'
              THEN interval '1 day' ELSE interval '0 days' END)
            AT TIME ZONE time_zone AT TIME ZONE 'UTC') END
      SQL
    end
    table = channel == "email" ? "alert_deliveries" : "in_app_notifications"
    sql = ApplicationRecord.sanitize_sql([ <<~SQL, now: as_of, channel: ])
      WITH candidates AS MATERIALIZED (
        SELECT DISTINCT ON (matched.rule_id, matched.news_item_id, matched.follow_id) matched.*, preferences.time_zone
        FROM (NEWS_MATCHES) matched
        INNER JOIN alert_rules rules ON rules.id = matched.rule_id AND rules.user_id = matched.user_id
        INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
        INNER JOIN follows ON follows.id = matched.follow_id AND follows.user_id = matched.user_id
        LEFT JOIN notification_preferences preferences ON preferences.user_id = rules.user_id
        WHERE rules.scope = 'watchlist' AND rules.active AND rules.event_type = 'news' AND rules.channel = :channel
          AND settings.archived_at IS NULL AND settings.revision = matched.rule_revision AND settings.frequency = matched.frequency
          AND matched.published_at >= settings.enabled_at AND matched.published_at >= follows.followed_at
          AND follows.removed_at IS NULL AND follows.followed_at = matched.followed_at
          AND follows.target_type = matched.target_type AND follows.target_key = matched.target_key
          AND (matched.frequency = 'instant' OR preferences.time_zone IS NOT NULL)
          AND (:channel <> 'email' OR (preferences.email_enabled AND preferences.email_enabled_at <= :now AND preferences.time_zone IS NOT NULL))
          AND EXISTS (NEWS_VALIDITY)
        ORDER BY matched.rule_id, matched.news_item_id, matched.follow_id, matched.news_alert_snapshot_id
      ), inserted AS (
        INSERT INTO #{table}
          (alert_rule_id, news_item_id, news_alert_snapshot_id, event_type, frequency, rule_revision, created_at, updated_at, #{columns})
        SELECT DISTINCT ON (rule_id, news_item_id)
          rule_id, news_item_id, news_alert_snapshot_id, 'news', frequency, rule_revision, :now, :now, #{extra}
        FROM candidates ORDER BY rule_id, news_item_id, news_alert_snapshot_id, follow_id
        ON CONFLICT (alert_rule_id, news_item_id) WHERE #{conflict} DO NOTHING
        RETURNING id, alert_rule_id, news_item_id
      )
      INSERT INTO watchlist_news_memberships
        (#{destination}, alert_rule_id, user_id, news_item_id, news_alert_snapshot_id, follow_id, followed_at,
          target_type, target_key, created_at, updated_at)
      SELECT inserted.id, candidates.rule_id, candidates.user_id, candidates.news_item_id, candidates.news_alert_snapshot_id,
        candidates.follow_id, candidates.followed_at, candidates.target_type, candidates.target_key, :now, :now
      FROM inserted INNER JOIN candidates ON candidates.rule_id = inserted.alert_rule_id AND candidates.news_item_id = inserted.news_item_id
    SQL
    connection.execute(sql.gsub(/NEWS_MATCHES|NEWS_VALIDITY/) { |key| key == "NEWS_MATCHES" ? source : valid })
    WatchlistEmailEnqueue.call(news_item_id: item.id, event_type: "news") if channel == "email"
  end
end
