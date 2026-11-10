# frozen_string_literal: true

class SendAlertJob < ApplicationJob
  queue_as :alerts
  discard_on ActiveRecord::RecordNotFound

  def perform(delivery_id)
    delivery = AlertDelivery.includes(:filing, alert_rule: { follow: :user }).find(delivery_id)
    delivery.with_lock do
      return if delivery.status == "sent" || !delivery.alert_rule.active?

      FilingAlertMailer.new_filing(delivery).deliver_now
      delivery.update!(status: "sent", delivered_at: Time.current, error: nil)
    end
  rescue StandardError => e
    delivery&.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(2000))
    raise
  end
end
