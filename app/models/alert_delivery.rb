# frozen_string_literal: true

class AlertDelivery < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  belongs_to :alert_rule
  belongs_to :filing
  belongs_to :insider_transaction, optional: true
  has_many :alert_event_states, dependent: :restrict_with_exception
  has_one :alert_digest_item, dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :frequency, inclusion: { in: AlertRuleSetting::FREQUENCIES }
  validates :event_type, inclusion: { in: AlertRule::EVENT_TYPES }
  validates :rule_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :filing_id, uniqueness: { scope: :alert_rule_id, conditions: -> { where(insider_transaction_id: nil) } }, unless: :insider_transaction_id?
  validates :insider_transaction_id, uniqueness: { scope: :alert_rule_id }, allow_nil: true
  validate do
    if (event_type == "insider_transaction") != insider_transaction_id.present? || (insider_transaction && insider_transaction.filing_id != filing_id)
      errors.add(:insider_transaction, "must match the source filing and trigger")
    end
  end
end
