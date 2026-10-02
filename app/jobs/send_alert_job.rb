# frozen_string_literal: true

class SendAlertJob < ApplicationJob
  queue_as :alerts

  def perform(delivery_id)
    delivery = AlertDelivery.includes(:filing, alert_rule: { follow: :user }).find(delivery_id)
    return if delivery.status == "sent"

    FilingAlertMailer.new_filing(delivery).deliver_now
    delivery.update!(status: "sent", delivered_at: Time.current, error: nil)
  rescue StandardError => e
    delivery&.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(2000))
    raise
  end
end
