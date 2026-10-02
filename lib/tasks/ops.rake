# frozen_string_literal: true

namespace :ops do
  desc "Poller lag, parse failure rate, queue depth and last successful poll"
  task status: :environment do
    puts JSON.pretty_generate(OpsMetrics.new.to_h)
  end
end
