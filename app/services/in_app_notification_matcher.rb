# frozen_string_literal: true

class InAppNotificationMatcher
  def self.call(filing, as_of: Time.current)
    return unless filing&.parse_status == "parsed" && Filing::SEC_INGEST_TYPES.include?(filing.form_type) && filing.filed_at && filing.filed_at <= as_of

    rules = AlertRule.joins(:follow, :setting)
      .joins("LEFT JOIN notification_preferences ON notification_preferences.user_id = follows.user_id")
      .where(active: true, channel: "in_app", event_type: "new_filing", follows: { removed_at: nil }, alert_rule_settings: { archived_at: nil })
      .where("alert_rule_settings.enabled_at <= ?", filing.filed_at)
      .where("alert_rule_settings.frequency = 'instant' OR notification_preferences.time_zone IS NOT NULL")
      .where(FilingFollowMatch.sql(filing))
    connection = ApplicationRecord.connection
    now = connection.quote(as_of)
    local_time = "(#{now}::timestamp AT TIME ZONE 'UTC' AT TIME ZONE notification_preferences.time_zone)"
    cutoff = "(date_trunc('day', #{local_time}) + interval '7 hours')"
    next_cutoff = "(CASE WHEN #{local_time} >= #{cutoff} THEN #{cutoff} + interval '1 day' ELSE #{cutoff} END)"
    due = "(#{next_cutoff} AT TIME ZONE notification_preferences.time_zone AT TIME ZONE 'UTC')"
    selected = rules.select(<<~SQL.squish)
      alert_rules.id, #{connection.quote(filing.id)}, alert_rule_settings.revision, alert_rule_settings.frequency,
      CASE WHEN alert_rule_settings.frequency = 'daily_digest' THEN notification_preferences.time_zone END,
      CASE WHEN alert_rule_settings.frequency = 'instant' THEN #{now}::timestamp ELSE #{due} END,
      #{now}::timestamp, #{now}::timestamp
    SQL
    connection.execute(<<~SQL)
      INSERT INTO in_app_notifications
        (alert_rule_id, filing_id, rule_revision, frequency, time_zone, available_at, created_at, updated_at)
      #{selected.to_sql}
      ON CONFLICT (alert_rule_id, filing_id) DO NOTHING
    SQL
    InAppNotificationPublisher.call(filing_id: filing.id, as_of:)
  end
end
