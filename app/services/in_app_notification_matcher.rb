# frozen_string_literal: true

class InAppNotificationMatcher
  def self.call(filing, as_of: Time.current)
    return unless filing&.parse_status == "parsed" && Filing::SEC_INGEST_TYPES.include?(filing.form_type) && filing.filed_at && filing.filed_at <= as_of

    capture(filing:, as_of:, event_type: "new_filing", source_sql: filing_matches(filing))
    transactions = TransactionAlertMatcher.sql(filing, as_of:, channel: "in_app")
    capture(filing:, as_of:, event_type: "insider_transaction", source_sql: transactions) if transactions
    clusters = ClusterAlertMatcher.call(filing, as_of:, channel: "in_app")
    capture(filing:, as_of:, event_type: "cluster", source_sql: snapshot_matches(clusters, source_key: "insider_cluster_snapshot_id")) if clusters.any?
    changes = InstitutionalAlertMatcher.call(filing, as_of:, channel: "in_app")
    capture(filing:, as_of:, event_type: "13f_change", source_sql: snapshot_matches(changes, source_key: "institutional_change_snapshot_id")) if changes.any?
    InAppNotificationPublisher.call(filing_id: [ filing.id, *(clusters + changes).map { |row| row.fetch("filing_id") } ].uniq, as_of:)
  end

  def self.news(item, as_of: Time.current)
    return unless item

    matches = NewsAlertMatcher.call(item, as_of:, channel: "in_app")
    return if matches.empty?

    fields = %w[rule_id frequency rule_revision news_item_id news_alert_snapshot_id]
    connection = ApplicationRecord.connection
    values = matches.map { |row| "(#{fields.map { |field| connection.quote(row.fetch(field)) }.join(', ')})" }.join(", ")
    source = "SELECT DISTINCT ON (id, news_item_id) * FROM (VALUES #{values}) AS news_matches(id, frequency, rule_revision, news_item_id, news_alert_snapshot_id) ORDER BY id, news_item_id, news_alert_snapshot_id"
    capture(filing: nil, as_of:, event_type: "news", source_sql: source)
    InAppNotificationPublisher.call(news_item_id: item.id, as_of:)
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

  def self.snapshot_matches(matches, source_key:)
    fields = %w[id frequency rule_revision filing_id] + [ source_key ]
    connection = ApplicationRecord.connection
    values = matches.map { |row| "(#{fields.map { |field| connection.quote(row.fetch(field)) }.join(', ')})" }.join(", ")
    "SELECT * FROM (VALUES #{values}) AS snapshot_matches(#{fields.join(', ')})"
  end
  private_class_method :snapshot_matches

  def self.capture(filing:, as_of:, event_type:, source_sql:)
    connection = ApplicationRecord.connection
    now = connection.quote(as_of)
    local_time = "(#{now}::timestamp AT TIME ZONE 'UTC' AT TIME ZONE notification_preferences.time_zone)"
    cutoff = "(date_trunc('day', #{local_time}) + interval '7 hours')"
    next_cutoff = "(CASE WHEN #{local_time} >= #{cutoff} THEN #{cutoff} + interval '1 day' ELSE #{cutoff} END)"
    due = "(#{next_cutoff} AT TIME ZONE notification_preferences.time_zone AT TIME ZONE 'UTC')"
    key = { "new_filing" => "alert_rule_id, filing_id", "insider_transaction" => "alert_rule_id, filing_id, security_table, txn_seq",
      "cluster" => "alert_rule_id, insider_cluster_snapshot_id", "13f_change" => "alert_rule_id, institutional_change_snapshot_id", "news" => "alert_rule_id, news_item_id" }.fetch(event_type)
    snapshot_event = %w[cluster 13f_change news].include?(event_type)
    source_filing = if event_type == "news" then "NULL::bigint"
    elsif snapshot_event then "matched.filing_id"
    else connection.quote(filing.id)
    end
    transaction = snapshot_event ? "NULL::bigint, NULL::varchar, NULL::integer" : "matched.insider_transaction_id, matched.security_table, matched.txn_seq"
    cluster = event_type == "cluster" ? "matched.insider_cluster_snapshot_id" : "NULL::bigint"
    institutional = event_type == "13f_change" ? "matched.institutional_change_snapshot_id" : "NULL::bigint"
    news = event_type == "news" ? "matched.news_item_id, matched.news_alert_snapshot_id" : "NULL::bigint, NULL::bigint"
    connection.execute(<<~SQL)
      INSERT INTO in_app_notifications
        (alert_rule_id, filing_id, rule_revision, frequency, time_zone, available_at, created_at, updated_at,
          event_type, insider_transaction_id, security_table, txn_seq, insider_cluster_snapshot_id, institutional_change_snapshot_id, news_item_id, news_alert_snapshot_id)
      SELECT matched.id, #{source_filing}, matched.rule_revision, matched.frequency,
        CASE WHEN matched.frequency = 'daily_digest' THEN notification_preferences.time_zone END,
        CASE WHEN matched.frequency = 'instant' THEN #{now}::timestamp ELSE #{due} END,
        #{now}::timestamp, #{now}::timestamp, #{connection.quote(event_type)}, #{transaction}, #{cluster}, #{institutional}, #{news}
      FROM (#{source_sql}) matched
      INNER JOIN alert_rules rules ON rules.id = matched.id
      INNER JOIN follows ON follows.id = rules.follow_id
      LEFT JOIN notification_preferences ON notification_preferences.user_id = rules.user_id
      WHERE matched.frequency = 'instant' OR notification_preferences.time_zone IS NOT NULL
      ON CONFLICT (#{key}) WHERE event_type = #{connection.quote(event_type)} DO NOTHING
    SQL
  end
  private_class_method :capture
end
