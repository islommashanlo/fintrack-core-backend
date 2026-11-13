# frozen_string_literal: true

class InAppNotificationReads
  def self.mark(user:, id:, as_of: Time.current)
    user.with_lock do
      record = user.in_app_notifications.visible_at(as_of).find(id)
      unless record.read_at
        record.update!(read_at: as_of)
        InAppInboxRealtime.after_commit([ user.id ])
      end
      record
    end
  end

  def self.mark_all(user:, as_of: Time.current)
    user.with_lock do
      visible = user.in_app_notifications.visible_at(as_of).select("in_app_notifications.id")
      now = ApplicationRecord.connection.quote(as_of)
      # One statement pins membership even if an older pending row publishes
      # concurrently; an ID ceiling alone cannot distinguish that arrival.
      row = ApplicationRecord.connection.select_one(<<~SQL)
        WITH visible AS MATERIALIZED (#{visible.to_sql}), updated AS (
          UPDATE in_app_notifications SET read_at = #{now}, updated_at = #{now}
          WHERE id IN (SELECT id FROM visible) AND read_at IS NULL RETURNING id
        )
        SELECT (SELECT COUNT(*) FROM updated) AS updated_count,
          (SELECT COALESCE(MAX(id), 0) FROM visible) AS through_id
      SQL
      InAppInboxRealtime.after_commit([ user.id ]) if row.fetch("updated_count").positive?
      { updated_count: row.fetch("updated_count"), through_id: row.fetch("through_id"), as_of: }
    end
  end
end
