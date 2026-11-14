# frozen_string_literal: true

namespace :ops do
  desc "Operator metrics, including per-form ingestion lag, backlog and failures"
  task status: :environment do
    puts JSON.pretty_generate(OpsMetrics.new.to_h)
  end

  desc "Read-only market-input inventory; does not certify readiness or activate scoring"
  task market_inputs: :environment do
    puts JSON.pretty_generate(MarketInputReadiness.new.to_h)
  end
end
