# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationWorkers do
  it "consumes notifications separately without adding mail queues to the SEC thread pool" do
    config = Sidekiq::Config.new
    config.queues = %w[sec_live_form4 sec_live_13f sec_backfill_13f]
    described_class.configure(config)
    notifications = config.capsules.fetch("notifications")
    expect(notifications.concurrency).to eq(2)
    expect(notifications.queues.uniq).to contain_exactly("alerts", "default")
    expect(config.default_capsule.queues).to eq(%w[sec_live_form4 sec_live_13f sec_backfill_13f])
    expect(config.default_capsule.concurrency).to eq(5)
  end
end
