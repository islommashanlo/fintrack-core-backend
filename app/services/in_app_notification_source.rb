# frozen_string_literal: true

class InAppNotificationSource
  def self.apply(scope, as_of:, max_filing_id: nil, max_report_id: nil)
    effective = Form4ReadScope.new(as_of:, max_filing_id:).effective_filings.select(:id).to_sql
    now = ApplicationRecord.connection.quote(as_of)
    reports = InstitutionalAlertValidity.report_sets_sql(as_of:, max_filing_id:, max_report_id:)
    scope.where(<<~SQL.squish)
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
        in_app_notifications.event_type = 'cluster' AND EXISTS (
          SELECT 1 FROM insider_cluster_snapshots snapshot
          WHERE snapshot.id = in_app_notifications.insider_cluster_snapshot_id
            AND snapshot.primary_filing_id = in_app_notifications.filing_id
            AND snapshot.observed_at <= #{now}
            AND snapshot.filing_ids @> ARRAY[in_app_notifications.filing_id]::bigint[]
            AND NOT EXISTS (
              SELECT 1 FROM unnest(snapshot.filing_ids) sources(id)
              WHERE sources.id NOT IN (#{effective})
            )
            AND NOT EXISTS (
              SELECT 1 FROM unnest(snapshot.transaction_ids) members(id)
              LEFT JOIN insider_transactions source ON source.id = members.id
              WHERE source.id IS NULL OR NOT (source.filing_id = ANY(snapshot.filing_ids))
                OR source.owner_seq <> 1 OR source.security_table <> 'non_derivative'
                OR source.transaction_code IS DISTINCT FROM snapshot.transaction_code
                OR source.issuer_cik IS DISTINCT FROM snapshot.issuer_cik
            )
        )
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
end
