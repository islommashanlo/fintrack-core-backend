# frozen_string_literal: true

class AlertDelivery < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  belongs_to :alert_rule
  belongs_to :filing, optional: true
  belongs_to :news_item, optional: true
  belongs_to :news_alert_snapshot, optional: true
  belongs_to :insider_transaction, optional: true
  belongs_to :insider_cluster_snapshot, optional: true
  belongs_to :institutional_change_snapshot, optional: true
  has_many :alert_event_states, dependent: :restrict_with_exception
  has_one :alert_digest_item, dependent: :restrict_with_exception

  validates :filing, presence: true, unless: -> { event_type == "news" }
  validates :news_item_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
  validates :frequency, inclusion: { in: AlertRuleSetting::FREQUENCIES }
  validates :event_type, inclusion: { in: AlertRule::EVENT_TYPES }
  validates :rule_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :filing_id, uniqueness: { scope: :alert_rule_id, conditions: -> { where(insider_transaction_id: nil, insider_cluster_snapshot_id: nil, institutional_change_snapshot_id: nil, news_item_id: nil) } }, if: -> { event_type == "new_filing" }
  validates :insider_transaction_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validates :insider_cluster_snapshot_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validates :institutional_change_snapshot_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validate do
    if event_type == "news"
      unless filing_id.nil? && news_item && news_alert_snapshot && news_alert_snapshot.news_item_id == news_item_id
        errors.add(:news_item, "must match the source snapshot without a SEC filing")
      end
    elsif news_item_id.present? || news_alert_snapshot_id.present?
      errors.add(:news_item, "requires the news trigger")
    end
    if (event_type == "insider_transaction") != insider_transaction_id.present? || (insider_transaction && insider_transaction.filing_id != filing_id)
      errors.add(:insider_transaction, "must match the source filing and trigger")
    end
    if (event_type == "cluster") != insider_cluster_snapshot_id.present? || (insider_cluster_snapshot && insider_cluster_snapshot.primary_filing_id != filing_id)
      errors.add(:insider_cluster_snapshot, "must match the source filing and trigger")
    end
    if (event_type == "13f_change") != institutional_change_snapshot_id.present? || (institutional_change_snapshot && institutional_change_snapshot.primary_filing_id != filing_id)
      errors.add(:institutional_change_snapshot, "must match the source filing and trigger")
    end
  end
end
