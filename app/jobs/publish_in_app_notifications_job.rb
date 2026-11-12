# frozen_string_literal: true

class PublishInAppNotificationsJob < ApplicationJob
  queue_as :alerts

  def perform
    InAppNotificationPublisher.call
  end
end
