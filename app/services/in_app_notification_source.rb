# frozen_string_literal: true

class InAppNotificationSource
  def self.apply(scope, as_of:, max_filing_id: nil, max_report_id: nil, max_news_item_id: nil, max_news_mention_id: nil)
    news = NewsAlertValidity.notification_sources(as_of:, max_filing_id:, max_news_item_id:, max_news_mention_id:)
    types = Filing::SEC_INGEST_TYPES.map { |type| ApplicationRecord.connection.quote(type) }.join(", ")
    now = ApplicationRecord.connection.quote(as_of)
    scope = scope.where(<<~SQL.squish)
      EXISTS (
        SELECT 1 FROM alert_rules source_rule WHERE source_rule.id = in_app_notifications.alert_rule_id
          AND (source_rule.scope = 'follow' OR (
            source_rule.scope = 'watchlist' AND source_rule.channel = 'in_app'
            AND ((in_app_notifications.event_type = 'news' AND EXISTS (
              SELECT 1 FROM watchlist_news_memberships witness
              WHERE witness.in_app_notification_id = in_app_notifications.id AND witness.alert_rule_id = source_rule.id
                AND witness.user_id = source_rule.user_id AND witness.news_item_id = in_app_notifications.news_item_id
            )) OR (in_app_notifications.event_type IN ('new_filing', 'insider_transaction', 'cluster', '13f_change') AND EXISTS (
              SELECT 1 FROM watchlist_filing_memberships witness
              WHERE witness.in_app_notification_id = in_app_notifications.id
                AND witness.user_id = source_rule.user_id AND witness.alert_rule_id = source_rule.id
                AND witness.filing_id = in_app_notifications.filing_id
            )))
          ))
      )
    SQL
    scope.where(<<~SQL.squish)
      (in_app_notifications.event_type = 'news' AND in_app_notifications.filing_id IS NULL AND EXISTS (#{news})) OR (
        filings.parse_status = 'parsed' AND filings.form_type IN (#{types}) AND filings.filed_at <= #{now}
        #{max_filing_id ? "AND filings.id <= #{Integer(max_filing_id)}" : ''}
        AND (#{filing_events_sql(as_of:, max_filing_id:, max_report_id:)})
      )
    SQL
  end

  def self.filing_events_sql(as_of:, max_filing_id:, max_report_id:)
    effective = Form4ReadScope.new(as_of:, max_filing_id:).effective_filings.select(:id).to_sql
    now = ApplicationRecord.connection.quote(as_of)
    reports = InstitutionalAlertValidity.report_sets_sql(as_of:, max_filing_id:, max_report_id:)
    <<~SQL.squish
      in_app_notifications.event_type = 'new_filing' OR (
        in_app_notifications.event_type = 'insider_transaction'
        AND in_app_notifications.filing_id IN (#{effective})
        AND EXISTS (
          SELECT 1 FROM insider_transactions source
          WHERE source.id = in_app_notifications.insider_transaction_id
            AND source.filing_id = in_app_notifications.filing_id
            AND source.security_table = in_app_notifications.security_table
            AND source.txn_seq = in_app_notifications.txn_seq
        )
      ) OR (
        in_app_notifications.event_type = 'cluster' AND #{ClusterAlertValidity.sql(
          snapshot_column: "in_app_notifications.insider_cluster_snapshot_id",
          filing_column: "in_app_notifications.filing_id", as_of:, max_filing_id:)}
      ) OR (
        in_app_notifications.event_type = '13f_change' AND EXISTS (
          SELECT 1 FROM institutional_change_snapshots snapshot
          WHERE snapshot.id = in_app_notifications.institutional_change_snapshot_id
            AND snapshot.primary_filing_id = in_app_notifications.filing_id
            AND snapshot.observed_at <= #{now}
            AND (#{reports})
        )
      )
    SQL
  end
  private_class_method :filing_events_sql
end
