# frozen_string_literal: true

class AlertRuleSetting < ApplicationRecord
  FREQUENCIES = %w[instant daily_digest].freeze
  belongs_to :alert_rule
  validates :alert_rule_id, uniqueness: true
  validates :frequency, inclusion: { in: FREQUENCIES }
  validate { errors.add(:conditions, "are not supported yet") unless conditions == {} }
end
