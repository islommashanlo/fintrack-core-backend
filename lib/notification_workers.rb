# frozen_string_literal: true

require "sidekiq/capsule"

module NotificationWorkers
  QUEUES = [ [ "alerts", 4 ].freeze, [ "default", 1 ].freeze ].freeze

  def self.configure(config)
    config.capsule("notifications") do |capsule|
      capsule.concurrency = 2
      capsule.queues = QUEUES
    end
  end
end
