# frozen_string_literal: true

class WatchlistFilingCandidates
  def self.sql(filing:, channel:, as_of:)
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)

    sql = ApplicationRecord.sanitize_sql([ <<~SQL, channel:, filed: filing.filed_at, now: as_of ])
      SELECT rules.id AS rule_id, rules.user_id, settings.frequency, settings.revision,
        follows.id AS follow_id, follows.followed_at, follows.target_type, follows.target_key,
        preferences.time_zone
      FROM alert_rules rules
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
      INNER JOIN follows ON follows.user_id = rules.user_id
      LEFT JOIN notification_preferences preferences ON preferences.user_id = rules.user_id
      WHERE rules.scope = 'watchlist' AND rules.active AND rules.channel = :channel
        AND rules.event_type = 'new_filing' AND settings.archived_at IS NULL
        AND follows.removed_at IS NULL AND :filed >= follows.followed_at AND :filed >= settings.enabled_at
        AND (WATCHLIST_FOLLOW_PREDICATE)
        AND (settings.frequency = 'instant' OR preferences.time_zone IS NOT NULL)
        AND (:channel <> 'email' OR (preferences.email_enabled AND preferences.email_enabled_at <= :now
          AND preferences.time_zone IS NOT NULL))
    SQL
    sql.sub("WATCHLIST_FOLLOW_PREDICATE") { FilingFollowMatch.sql(filing) }
  end
end
