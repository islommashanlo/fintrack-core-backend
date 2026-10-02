# frozen_string_literal: true

# Runs every minute for live 13F-HR, 13F-HR/A and 13F-NT detection.
class Poll13fJob < ApplicationJob
  queue_as :sec_live_13f
  sidekiq_options retry: 0 if respond_to?(:sidekiq_options)

  def perform
    Edgar13fPoller.new.poll
  rescue SecClient::Error, Edgar::FullTextSearch::UnexpectedResponse => e
    Rails.logger.warn("EDGAR 13F poll failed: #{e.class}: #{e.message}")
  end
end
