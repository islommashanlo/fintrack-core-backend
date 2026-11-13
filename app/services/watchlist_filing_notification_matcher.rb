# frozen_string_literal: true

# One statement creates a rule/filing notice and its immutable membership witnesses.
# A conflicting notice returns no rows, so retries cannot add new membership epochs.
class WatchlistFilingNotificationMatcher
  def self.call(filing, as_of: Time.current)
    return unless filing&.parse_status == "parsed" && filing.form_type.in?(Filing::SEC_INGEST_TYPES)
    return unless filing.filed_at && filing.filed_at <= as_of

    sql = ApplicationRecord.sanitize_sql([ <<~SQL, filing: filing.id, filed: filing.filed_at, now: as_of ])
      WITH candidates AS MATERIALIZED (
        SELECT rules.id AS rule_id, rules.user_id, settings.frequency, settings.revision,
          follows.id AS follow_id, follows.followed_at, follows.target_type, follows.target_key,
          preferences.time_zone
        FROM alert_rules rules
        INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
        INNER JOIN follows ON follows.user_id = rules.user_id
        LEFT JOIN notification_preferences preferences ON preferences.user_id = rules.user_id
        WHERE rules.scope = 'watchlist' AND rules.active AND rules.channel = 'in_app'
          AND rules.event_type = 'new_filing' AND settings.archived_at IS NULL
          AND follows.removed_at IS NULL AND :filed >= follows.followed_at AND :filed >= settings.enabled_at
          AND (WATCHLIST_FOLLOW_PREDICATE)
          AND (settings.frequency = 'instant' OR preferences.time_zone IS NOT NULL)
      ), inserted AS (
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
    ApplicationRecord.connection.execute(sql.sub("WATCHLIST_FOLLOW_PREDICATE") { FilingFollowMatch.sql(filing) })
  end
end
