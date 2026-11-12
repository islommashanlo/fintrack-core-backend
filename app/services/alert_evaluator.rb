# frozen_string_literal: true

# Matches filing, transaction-line and rolling-cluster rules from local sources.
# SQL resolves membership before source-level deduplication.
class AlertEvaluator
  def self.call(filing)
    new(filing:).call
  end

  def initialize(filing:)
    @filing = filing
  end

  def call
    return [] unless @filing&.parse_status == "parsed"

    InAppNotificationMatcher.call(@filing)
    enqueue(matching_rules, event_type: "new_filing", unique_by: :index_alert_deliveries_on_alert_rule_id_and_filing_id) +
      enqueue(TransactionAlertMatcher.call(@filing), event_type: "insider_transaction", unique_by: :index_alert_deliveries_on_rule_and_transaction) +
      enqueue(ClusterAlertMatcher.call(@filing), event_type: "cluster", unique_by: :index_alert_deliveries_on_rule_and_cluster) +
      enqueue(InstitutionalAlertMatcher.call(@filing), event_type: "13f_change", unique_by: :index_alert_deliveries_on_rule_and_institutional_change)
  end

  private

  def enqueue(matches, event_type:, unique_by:)
    rows = matches.map do |rule|
      { alert_rule_id: rule.fetch("id"), filing_id: rule["filing_id"] || @filing.id, status: "pending", frequency: rule.fetch("frequency"),
        event_type:, rule_revision: rule.fetch("rule_revision"), insider_transaction_id: rule["insider_transaction_id"],
        insider_cluster_snapshot_id: rule["insider_cluster_snapshot_id"],
        institutional_change_snapshot_id: rule["institutional_change_snapshot_id"],
        created_at: Time.current, updated_at: Time.current }
    end
    return [] if rows.empty?

    inserted = AlertDelivery.insert_all(
      rows,
      unique_by:,
      returning: %w[id frequency]
    )
    inserted.rows.filter_map { |id, frequency| SendAlertJob.perform_later(id) if frequency == "instant" }
  end

  def matching_rules
    return [] unless Filing::SEC_INGEST_TYPES.include?(@filing.form_type)

    ApplicationRecord.connection.select_all("#{base_sql} AND #{FilingFollowMatch.sql(@filing)}").to_a
  end

  def base_sql
    <<~SQL
      SELECT alert_rules.id, settings.frequency, settings.revision AS rule_revision
      FROM alert_rules
      INNER JOIN follows ON follows.id = alert_rules.follow_id
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = alert_rules.id
      WHERE alert_rules.active
        AND follows.removed_at IS NULL AND settings.archived_at IS NULL
        AND alert_rules.event_type = 'new_filing'
        AND alert_rules.channel = 'email'
    SQL
  end
end
