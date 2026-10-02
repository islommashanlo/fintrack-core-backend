# frozen_string_literal: true

class EnrichCusipsJob < ApplicationJob
  queue_as :default

  retry_on OpenfigiClient::TransientError, attempts: 4, wait: :polynomially_longer

  def perform(cusips)
    plan = OpenfigiEnrichment.new.plan(cusips:)
    OpenfigiEnrichment.new.execute(plan)
  end
end
