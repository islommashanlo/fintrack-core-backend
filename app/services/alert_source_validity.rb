# frozen_string_literal: true

class AlertSourceValidity
  def self.apply(scope, as_of:)
    now = ApplicationRecord.connection.quote(as_of)
    types = Filing::SEC_INGEST_TYPES.map { |type| ApplicationRecord.connection.quote(type) }.join(", ")
    scope = scope.where(<<~SQL.squish)
      EXISTS (SELECT 1 FROM alert_rules source_rule WHERE source_rule.id = alert_deliveries.alert_rule_id
        AND (source_rule.scope = 'follow' OR (
          source_rule.scope = 'watchlist' AND alert_deliveries.event_type = 'new_filing'
          AND EXISTS (SELECT 1 FROM filings source WHERE source.id = alert_deliveries.filing_id
            AND source.parse_status = 'parsed' AND source.form_type IN (#{types}) AND source.filed_at <= #{now})
          AND EXISTS (SELECT 1 FROM watchlist_filing_memberships witness
            WHERE witness.alert_delivery_id = alert_deliveries.id AND witness.user_id = source_rule.user_id
              AND witness.alert_rule_id = source_rule.id AND witness.filing_id = alert_deliveries.filing_id)
        )))
    SQL
    effective = Form4ReadScope.new(as_of:).effective_filings.select(:id)
    scope = scope.where("alert_deliveries.insider_transaction_id IS NULL OR alert_deliveries.filing_id IN (?)", effective)
      .where(<<~SQL.squish)
        alert_deliveries.insider_cluster_snapshot_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM insider_cluster_snapshots snapshot
          CROSS JOIN LATERAL unnest(snapshot.filing_ids) sources(id)
          WHERE snapshot.id = alert_deliveries.insider_cluster_snapshot_id
            AND sources.id NOT IN (#{effective.to_sql})
        )
      SQL
    NewsAlertValidity.apply(InstitutionalAlertValidity.apply(scope, as_of:), as_of:)
  end
end
