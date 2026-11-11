# frozen_string_literal: true

class AlertRuleSetting < ApplicationRecord
  FREQUENCIES = %w[instant daily_digest].freeze
  belongs_to :alert_rule
  validates :alert_rule_id, uniqueness: true
  validates :frequency, inclusion: { in: FREQUENCIES }
  validates :revision, numericality: { only_integer: true, greater_than: 0 }
  validate do
    normalized = TransactionAlertConditions.normalize(conditions)
    errors.add(:conditions, "do not match the trigger") if conditions != normalized || (alert_rule.event_type == "new_filing" && conditions != {})
  rescue TransactionAlertConditions::Invalid
    errors.add(:conditions, "are invalid")
  end
end
