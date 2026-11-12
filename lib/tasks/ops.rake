# frozen_string_literal: true

namespace :ops do
  desc "Operator metrics, including per-form ingestion lag, backlog and failures"
  task status: :environment do
    puts JSON.pretty_generate(OpsMetrics.new.to_h)
  end
end
