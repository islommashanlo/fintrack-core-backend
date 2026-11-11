# frozen_string_literal: true

class AlertSourceValidity
  def self.apply(scope, as_of:)
    effective = Form4ReadScope.new(as_of:).effective_filings.select(:id)
    scope.where("alert_deliveries.insider_transaction_id IS NULL OR alert_deliveries.filing_id IN (?)", effective)
      .where(<<~SQL.squish)
        alert_deliveries.insider_cluster_snapshot_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM insider_cluster_snapshots snapshot
          CROSS JOIN LATERAL unnest(snapshot.filing_ids) sources(id)
          WHERE snapshot.id = alert_deliveries.insider_cluster_snapshot_id
            AND sources.id NOT IN (#{effective.to_sql})
        )
      SQL
  end
end
