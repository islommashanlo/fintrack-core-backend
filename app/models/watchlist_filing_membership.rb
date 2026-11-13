# frozen_string_literal: true

class WatchlistFilingMembership < ApplicationRecord
  belongs_to :in_app_notification, optional: true
  belongs_to :alert_delivery, optional: true
  belongs_to :alert_rule
  belongs_to :user
  belongs_to :filing
  belongs_to :follow

  def readonly?
    persisted?
  end

  DESTINATIONS = { "in_app" => [ "in_app_notification_id", "in_app_notifications" ],
    "email" => [ "alert_delivery_id", "alert_deliveries" ] }.freeze

  def self.pending_sql(channel: "in_app")
    column, table = DESTINATIONS.fetch(channel)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM watchlist_filing_memberships witness
        INNER JOIN follows live ON live.id = witness.follow_id AND live.user_id = witness.user_id
        WHERE witness.#{column} = #{table}.id
          AND witness.alert_rule_id = alert_rules.id AND witness.user_id = alert_rules.user_id
          AND witness.filing_id = #{table}.filing_id
          AND live.removed_at IS NULL AND live.followed_at = witness.followed_at
          AND live.target_type = witness.target_type AND live.target_key = witness.target_key
      )
    SQL
  end

  def self.summaries(ids, channel: "in_app")
    column, = DESTINATIONS.fetch(channel)
    return {} if ids.empty?

    sql = sanitize_sql_array([ <<~SQL, ids ])
      WITH ranked AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY #{column} ORDER BY follow_id, id) AS seq,
          COUNT(*) OVER (PARTITION BY #{column}) AS total
        FROM watchlist_filing_memberships WHERE #{column} IN (?)
      )
      SELECT #{column} AS destination_id, MAX(total) AS total_count,
        jsonb_agg(jsonb_build_object('follow_id', follow_id, 'target_type', target_type, 'key', target_key,
          'followed_at', to_char(followed_at, 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')) ORDER BY seq)
          FILTER (WHERE seq <= 20) AS entities
      FROM ranked GROUP BY #{column}
    SQL
    Api::V1::CursorPage.sql_rows(sql).index_by { |row| row.fetch("destination_id") }
  end
end
