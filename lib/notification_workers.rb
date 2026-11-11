# frozen_string_literal: true

require "sidekiq/capsule"

module NotificationWorkers
  def self.configure(config)
    config.capsule("notifications") do |capsule|
      capsule.concurrency = 2
      capsule.queues = [ [ "alerts", 4 ], [ "default", 1 ] ]
    end
  end
end
