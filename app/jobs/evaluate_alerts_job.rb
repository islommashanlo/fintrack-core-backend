# frozen_string_literal: true

class EvaluateAlertsJob < ApplicationJob
  queue_as :alerts

  def perform(filing_id)
    filing = Filing.find_by(id: filing_id)
    AlertEvaluator.call(filing) if filing
  end
end
