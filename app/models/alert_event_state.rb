# frozen_string_literal: true

class AlertEventState < ApplicationRecord
  belongs_to :user
  belongs_to :alert_delivery
  validates :alert_delivery_id, uniqueness: { scope: :user_id }
  validates :read_at, presence: true
  validate do
    errors.add(:alert_delivery, "must belong to the user") if alert_delivery && alert_delivery.alert_rule.user_id != user_id
  end
end
