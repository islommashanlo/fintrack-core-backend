# frozen_string_literal: true

class ProcessStripeEventJob < ApplicationJob
  queue_as :default
  retry_on Billing::StripeClient::TransientError, wait: :polynomially_longer, attempts: 4 do |job, _error|
    BillingEvent.where(id: job.arguments.first, status: "failed").update_all(reason: "retries_exhausted", updated_at: Time.current)
  end

  def perform(event_id)
    Billing::ProcessEvent.call(event_id)
  end
end
