# frozen_string_literal: true

# One statement creates a rule/filing notice and its immutable membership witnesses.
# A conflicting notice returns no rows, so retries cannot add new membership epochs.
class WatchlistFilingNotificationMatcher
  def self.call(filing, as_of: Time.current)
    return unless filing&.parse_status == "parsed" && filing.form_type.in?(Filing::SEC_INGEST_TYPES)
    return unless filing.filed_at && filing.filed_at <= as_of

    sql = ApplicationRecord.sanitize_sql([ <<~SQL, filing: filing.id, now: as_of ])
      WITH candidates AS MATERIALIZED (WATCHLIST_CANDIDATES), inserted AS (
        INSERT INTO in_app_notifications
          (alert_rule_id, filing_id, event_type, frequency, rule_revision, time_zone,
            available_at, created_at, updated_at)
        SELECT DISTINCT ON (rule_id) rule_id, :filing, 'new_filing', frequency, revision,
          CASE WHEN frequency = 'daily_digest' THEN time_zone END,
          CASE WHEN frequency = 'instant' THEN :now::timestamp ELSE
            ((date_trunc('day', :now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone) + interval '7 hours'
              + CASE WHEN (:now::timestamp AT TIME ZONE 'UTC' AT TIME ZONE time_zone)::time >= time '07:00'
                THEN interval '1 day' ELSE interval '0 days' END)
              AT TIME ZONE time_zone AT TIME ZONE 'UTC') END,
          :now, :now FROM candidates ORDER BY rule_id, follow_id
        ON CONFLICT (alert_rule_id, filing_id) WHERE event_type = 'new_filing' DO NOTHING
        RETURNING id, alert_rule_id
      )
      INSERT INTO watchlist_filing_memberships
        (in_app_notification_id, alert_rule_id, user_id, filing_id, follow_id, followed_at,
          target_type, target_key, created_at, updated_at)
      SELECT inserted.id, candidates.rule_id, candidates.user_id, :filing, candidates.follow_id,
        candidates.followed_at, candidates.target_type, candidates.target_key, :now, :now
      FROM inserted INNER JOIN candidates ON candidates.rule_id = inserted.alert_rule_id
    SQL
    ApplicationRecord.connection.execute(sql.sub("WATCHLIST_CANDIDATES") { WatchlistFilingCandidates.sql(filing:, channel: "in_app", as_of:) })
  end
end
