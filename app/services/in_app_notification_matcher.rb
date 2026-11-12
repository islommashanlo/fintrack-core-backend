# frozen_string_literal: true

class InAppNotificationMatcher
  def self.call(filing, as_of: Time.current)
    return unless filing&.parse_status == "parsed" && Filing::SEC_INGEST_TYPES.include?(filing.form_type) && filing.filed_at && filing.filed_at <= as_of

    capture(filing:, as_of:, event_type: "new_filing", source_sql: filing_matches(filing))
    transactions = TransactionAlertMatcher.sql(filing, as_of:, channel: "in_app")
    capture(filing:, as_of:, event_type: "insider_transaction", source_sql: transactions) if transactions
    InAppNotificationPublisher.call(filing_id: filing.id, as_of:)
  end

  def self.filing_matches(filing)
    AlertRule.joins(:follow, :setting)
      .where(active: true, channel: "in_app", event_type: "new_filing", follows: { removed_at: nil }, alert_rule_settings: { archived_at: nil })
      .where("alert_rule_settings.enabled_at <= ?", filing.filed_at)
      .where(FilingFollowMatch.sql(filing))
      .select("alert_rules.id, alert_rule_settings.frequency, alert_rule_settings.revision AS rule_revision,
        NULL::bigint AS insider_transaction_id, NULL::varchar AS security_table, NULL::integer AS txn_seq").to_sql
  end
  private_class_method :filing_matches

  def self.capture(filing:, as_of:, event_type:, source_sql:)
    connection = ApplicationRecord.connection
    now = connection.quote(as_of)
    local_time = "(#{now}::timestamp AT TIME ZONE 'UTC' AT TIME ZONE notification_preferences.time_zone)"
    cutoff = "(date_trunc('day', #{local_time}) + interval '7 hours')"
    next_cutoff = "(CASE WHEN #{local_time} >= #{cutoff} THEN #{cutoff} + interval '1 day' ELSE #{cutoff} END)"
    due = "(#{next_cutoff} AT TIME ZONE notification_preferences.time_zone AT TIME ZONE 'UTC')"
    key = event_type == "new_filing" ? "alert_rule_id, filing_id" : "alert_rule_id, filing_id, security_table, txn_seq"
    connection.execute(<<~SQL)
      INSERT INTO in_app_notifications
        (alert_rule_id, filing_id, rule_revision, frequency, time_zone, available_at, created_at, updated_at,
          event_type, insider_transaction_id, security_table, txn_seq)
      SELECT matched.id, #{connection.quote(filing.id)}, matched.rule_revision, matched.frequency,
        CASE WHEN matched.frequency = 'daily_digest' THEN notification_preferences.time_zone END,
        CASE WHEN matched.frequency = 'instant' THEN #{now}::timestamp ELSE #{due} END,
        #{now}::timestamp, #{now}::timestamp, #{connection.quote(event_type)}, matched.insider_transaction_id, matched.security_table, matched.txn_seq
      FROM (#{source_sql}) matched
      INNER JOIN alert_rules rules ON rules.id = matched.id
      INNER JOIN follows ON follows.id = rules.follow_id
      LEFT JOIN notification_preferences ON notification_preferences.user_id = follows.user_id
      WHERE matched.frequency = 'instant' OR notification_preferences.time_zone IS NOT NULL
      ON CONFLICT (#{key}) WHERE event_type = #{connection.quote(event_type)} DO NOTHING
    SQL
  end
  private_class_method :capture
end
