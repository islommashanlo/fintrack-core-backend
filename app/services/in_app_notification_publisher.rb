# frozen_string_literal: true

class InAppNotificationPublisher
  BATCH_SIZE = 1000

  def self.call(filing_id: nil, as_of: Time.current)
    InAppNotification.transaction do
      scope = InAppNotificationPolicy.pending(as_of:).where("in_app_notifications.available_at <= ?", as_of)
      scope = scope.where(filing_id:) if filing_id
      ids = scope.order(:available_at, :id).limit(BATCH_SIZE)
        .lock("FOR UPDATE OF alert_rules SKIP LOCKED").pluck("in_app_notifications.id")
      InAppNotification.where(id: ids, published_at: nil).update_all(published_at: as_of, updated_at: as_of)
    end
  end
end
