# frozen_string_literal: true

class InAppNotificationSource
  def self.apply(scope, as_of:, max_filing_id: nil)
    effective = Form4ReadScope.new(as_of:, max_filing_id:).effective_filings.select(:id).to_sql
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
      )
    SQL
  end
end
