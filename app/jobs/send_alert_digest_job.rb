# frozen_string_literal: true

class SendAlertDigestJob < ApplicationJob
  queue_as :alerts
  discard_on ActiveRecord::RecordNotFound

  def perform(batch_id)
    batch = AlertDigestBatch.find(batch_id)
    user = batch.user
    claimed = user.with_lock do
      batch.reload
      next false unless %w[pending failed].include?(batch.status)
      batch.update!(status: "sending", started_at: Time.current, error: nil)
      true
    end
    return unless claimed

    provider_accepted = false
    user.with_lock do
      ids = AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")
        .where(id: batch.alert_deliveries.select(:id)).where.not(status: "sent").pluck(:id)
      ids = [] if user.notification_preference&.time_zone != batch.time_zone
      if ids.empty?
        batch.update!(status: "canceled")
        return
      end
      FilingDigestMailer.daily(batch, ids).deliver_now
      provider_accepted = true
      batch.update!(status: "sent", delivered_at: Time.current)
      batch.alert_deliveries.where(id: ids).update_all(status: "sent", delivered_at: Time.current, error: nil, updated_at: Time.current)
    end
  rescue StandardError => e
    # A provider-accepted batch stays 'sending' on database failure: do not resend blindly.
    batch&.update!(status: "failed", error: "#{e.class}: #{e.message}".truncate(2000)) unless provider_accepted
    raise
  end
end
