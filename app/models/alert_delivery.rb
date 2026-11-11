# frozen_string_literal: true

class AlertDelivery < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  belongs_to :alert_rule
  belongs_to :filing
  has_many :alert_event_states, dependent: :restrict_with_exception
  has_one :alert_digest_item, dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :frequency, inclusion: { in: AlertRuleSetting::FREQUENCIES }
  validates :filing_id, uniqueness: { scope: :alert_rule_id }
end
