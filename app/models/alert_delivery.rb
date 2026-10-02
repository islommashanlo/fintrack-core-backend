# frozen_string_literal: true

class AlertDelivery < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  belongs_to :alert_rule
  belongs_to :filing

  validates :status, inclusion: { in: STATUSES }
  validates :filing_id, uniqueness: { scope: :alert_rule_id }
end
