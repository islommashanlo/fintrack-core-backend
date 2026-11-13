# frozen_string_literal: true

class WatchlistSnapshotCapture
  FIELDS = { id: "bigint", user_id: "bigint", frequency: "varchar", rule_revision: "integer",
    filing_id: "bigint", follow_id: "bigint",
    followed_at: "timestamp", target_type: "varchar", target_key: "varchar", time_zone: "varchar" }.freeze

  SOURCES = { "cluster" => "insider_cluster_snapshot_id", "13f_change" => "institutional_change_snapshot_id" }.freeze

  def self.call(matches:, event_type:, channel:, trigger_at:, as_of:)
    source_key = SOURCES.fetch(event_type)
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)
    return [] if matches.empty?

    fields = FIELDS.merge(source_key => "bigint")
    connection = ApplicationRecord.connection
    values = matches.map do |row|
      "(#{fields.map { |key, type| "#{connection.quote(row.fetch(key.to_s))}::#{type}" }.join(', ')})"
    end.join(", ")
    source = "SELECT * FROM (VALUES #{values}) AS matched(#{fields.keys.join(', ')})"
    columns, extra, conflict, destination = if channel == "email"
      [ "status", "'pending'", "#{source_key} IS NOT NULL", "alert_delivery_id" ]
    else
      [ "time_zone, available_at", <<~SQL.squish, "event_type = #{connection.quote(event_type)}", "in_app_notification_id" ]
        CASE WHEN frequency = 'daily_digest' THEN time_zone END,
        CASE WHEN frequency = 'instant' THEN :now::timestamp ELSE
          ((date_trunc('day', :now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone) + interval '7 hours'
            + CASE WHEN (:now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone)::time >= time '07:00'
              THEN interval '1 day' ELSE interval '0 days' END)
            AT TIME ZONE time_zone AT TIME ZONE 'UTC') END
      SQL
    end
    table = channel == "email" ? "alert_deliveries" : "in_app_notifications"
    sql = ApplicationRecord.sanitize_sql([ <<~SQL, now: as_of, channel:, filed_at: trigger_at, event_type: ])
      WITH candidates AS MATERIALIZED (
        SELECT matched.* FROM (SNAPSHOT_MATCHES) matched
        INNER JOIN alert_rules rules ON rules.id = matched.id AND rules.user_id = matched.user_id
        INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
        INNER JOIN follows ON follows.id = matched.follow_id AND follows.user_id = matched.user_id
        LEFT JOIN notification_preferences preferences ON preferences.user_id = rules.user_id
        WHERE rules.scope = 'watchlist' AND rules.active AND rules.event_type = :event_type AND rules.channel = :channel
          AND settings.archived_at IS NULL AND settings.revision = matched.rule_revision
          AND settings.frequency = matched.frequency AND settings.enabled_at <= :filed_at
          AND follows.removed_at IS NULL AND follows.followed_at = matched.followed_at
          AND follows.target_type = matched.target_type AND follows.target_key = matched.target_key
          AND follows.followed_at <= :filed_at
          AND (matched.frequency = 'instant' OR matched.time_zone = preferences.time_zone)
          AND (:channel <> 'email' OR (preferences.email_enabled AND preferences.email_enabled_at <= :now
            AND preferences.time_zone IS NOT NULL))
      ), inserted AS (
        INSERT INTO #{table}
          (alert_rule_id, filing_id, #{source_key}, event_type, frequency, rule_revision,
            created_at, updated_at, #{columns})
        SELECT DISTINCT ON (id, #{source_key})
          id, filing_id, #{source_key}, :event_type, frequency, rule_revision, :now, :now, #{extra}
        FROM candidates ORDER BY id, #{source_key}, follow_id
        ON CONFLICT (alert_rule_id, #{source_key}) WHERE #{conflict} DO NOTHING
        RETURNING id, alert_rule_id, #{source_key}
      )
      INSERT INTO watchlist_filing_memberships
        (#{destination}, alert_rule_id, user_id, filing_id, follow_id, followed_at,
          target_type, target_key, created_at, updated_at)
      SELECT inserted.id, candidates.id, candidates.user_id, candidates.filing_id, candidates.follow_id,
        candidates.followed_at, candidates.target_type, candidates.target_key, :now, :now
      FROM inserted INNER JOIN candidates ON candidates.id = inserted.alert_rule_id
        AND candidates.#{source_key} = inserted.#{source_key}
    SQL
    connection.execute(sql.sub("SNAPSHOT_MATCHES") { source })
    filing_ids = matches.map { |row| row.fetch("filing_id") }.uniq
    WatchlistEmailEnqueue.call(filing_id: filing_ids, event_type:) if channel == "email"
    filing_ids
  end
end
