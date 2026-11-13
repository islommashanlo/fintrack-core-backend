# frozen_string_literal: true

module WatchlistMembershipSummaries
  extend ActiveSupport::Concern

  class_methods do
    def summaries(ids, channel: "in_app")
      column, = self::DESTINATIONS.fetch(channel)
      return {} if ids.empty?

      sql = sanitize_sql_array([ <<~SQL, ids ])
        WITH ranked AS (
          SELECT *, ROW_NUMBER() OVER (PARTITION BY #{column} ORDER BY follow_id, id) AS seq,
            COUNT(*) OVER (PARTITION BY #{column}) AS total
          FROM #{table_name} WHERE #{column} IN (?)
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
end
