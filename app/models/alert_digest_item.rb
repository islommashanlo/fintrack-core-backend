# frozen_string_literal: true

class AlertDigestItem < ApplicationRecord
  belongs_to :alert_digest_batch
  belongs_to :alert_delivery
  validates :alert_delivery_id, uniqueness: true
  validate do
    if alert_delivery && alert_digest_batch && alert_delivery.alert_rule.follow.user_id != alert_digest_batch.user_id
      errors.add(:alert_delivery, "must belong to the digest owner")
    end
  end
end
