# frozen_string_literal: true

class InAppNotification < ApplicationRecord
  belongs_to :alert_rule
  belongs_to :filing, optional: true
  belongs_to :news_item, optional: true
  belongs_to :news_alert_snapshot, optional: true
  validates :filing, presence: true, unless: -> { event_type == "news" }
  validates :news_item_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  belongs_to :insider_transaction, optional: true
  belongs_to :insider_cluster_snapshot, optional: true
  belongs_to :institutional_change_snapshot, optional: true
  validates :event_type, inclusion: { in: AlertRule::IN_APP_EVENT_TYPES }
  validates :filing_id, uniqueness: { scope: :alert_rule_id, conditions: -> { where(event_type: "new_filing") } }, if: -> { event_type == "new_filing" }
  validates :txn_seq, uniqueness: { scope: [ :alert_rule_id, :filing_id, :security_table ], conditions: -> { where(event_type: "insider_transaction") } }, if: -> { event_type == "insider_transaction" }
  validates :insider_cluster_snapshot_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validates :institutional_change_snapshot_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validate do
    if event_type == "news"
      unless filing_id.nil? && news_item && news_alert_snapshot && news_alert_snapshot.news_item_id == news_item_id
        errors.add(:news_item, "must match the news snapshot without a SEC filing")
      end
    elsif news_item_id || news_alert_snapshot_id
      errors.add(:news_item, "requires the news trigger")
    end
    if event_type == "13f_change"
      errors.add(:institutional_change_snapshot, "must match the primary source filing") unless institutional_change_snapshot && institutional_change_snapshot.primary_filing_id == filing_id
    elsif institutional_change_snapshot_id
      errors.add(:institutional_change_snapshot, "requires the institutional trigger")
    end
    if event_type == "cluster"
      errors.add(:insider_cluster_snapshot, "must match the primary source filing") unless insider_cluster_snapshot && insider_cluster_snapshot.primary_filing_id == filing_id
    elsif insider_cluster_snapshot_id
      errors.add(:insider_cluster_snapshot, "requires the cluster trigger")
    end
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

  scope :visible_at, ->(time, max_filing_id: nil, max_report_id: nil, max_news_item_id: nil, max_news_mention_id: nil) {
    scope = left_joins(:filing).where("in_app_notifications.published_at <= ?", time)
    InAppNotificationSource.apply(scope, as_of: time, max_filing_id:, max_report_id:, max_news_item_id:, max_news_mention_id:)
  }
end
