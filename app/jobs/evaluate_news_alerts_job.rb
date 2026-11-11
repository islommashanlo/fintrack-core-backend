# frozen_string_literal: true

class EvaluateNewsAlertsJob < ApplicationJob
  queue_as :alerts
  self.enqueue_after_transaction_commit = true

  def perform(item_id)
    NewsAlertEvaluator.call(NewsItem.find_by(id: item_id))
  end
end
