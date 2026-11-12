# frozen_string_literal: true

class InAppNotification < ApplicationRecord
  belongs_to :alert_rule
  belongs_to :filing
  belongs_to :insider_transaction, optional: true
  validates :event_type, inclusion: { in: AlertRule::IN_APP_EVENT_TYPES }
  validates :filing_id, uniqueness: { scope: :alert_rule_id, conditions: -> { where(event_type: "new_filing") } }, if: -> { event_type == "new_filing" }
  validates :txn_seq, uniqueness: { scope: [ :alert_rule_id, :filing_id, :security_table ], conditions: -> { where(event_type: "insider_transaction") } }, if: -> { event_type == "insider_transaction" }
  validate do
    if event_type == "insider_transaction"
      unless insider_transaction && insider_transaction.filing_id == filing_id && insider_transaction.security_table == security_table && insider_transaction.txn_seq == txn_seq
        errors.add(:insider_transaction, "must match the filing and transaction line")
      end
    elsif insider_transaction_id || security_table || txn_seq
      errors.add(:insider_transaction, "requires the transaction trigger")
    end
  end
  validates :frequency, inclusion: { in: AlertRuleSetting::FREQUENCIES }
  validates :rule_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :available_at, presence: true

  scope :visible_at, ->(time, max_filing_id: nil) {
    scope = joins(:filing).where("in_app_notifications.published_at <= ? AND filings.filed_at <= ?", time, time)
      .where(filings: { parse_status: "parsed", form_type: Filing::SEC_INGEST_TYPES })
    scope = scope.where("filings.id <= ?", max_filing_id) if max_filing_id
    InAppNotificationSource.apply(scope, as_of: time, max_filing_id:)
  }
end
