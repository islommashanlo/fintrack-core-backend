# frozen_string_literal: true

class SendAlertJob < ApplicationJob
  queue_as :alerts
  discard_on ActiveRecord::RecordNotFound

  def perform(delivery_id)
    delivery = AlertDelivery.includes(:filing, :insider_transaction, :insider_cluster_snapshot, :news_alert_snapshot,
      institutional_change_snapshot: :institutional_filer, alert_rule: { follow: :user }).find(delivery_id)
    user = delivery.alert_rule.follow.user
    user.with_lock do
      delivery.with_lock do
        return if delivery.status == "sent" || !AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "instant")

        mailer = delivery.event_type == "news" ? FilingAlertMailer.news_item(delivery) : FilingAlertMailer.new_filing(delivery)
        mailer.deliver_now
        delivery.update!(status: "sent", delivered_at: Time.current, error: nil)
      end
    end
  rescue StandardError => e
    delivery&.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(2000))
    raise
  end
end
