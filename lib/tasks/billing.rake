# frozen_string_literal: true

namespace :billing do
  %w[events checkouts].each do |kind|
    desc "Preview #{kind} recovery; CONFIRM=recover and MAX_REQUESTS=N execute bounded provider GETs"
    task "recover_#{kind}" => :environment do
      begin
        ids = ENV.fetch("IDS", "").split(",", -1).map { |id| Integer(id, 10) } unless ENV.fetch("IDS", "").empty?
        review = ENV.fetch("INCLUDE_REVIEW", "0")
        raise Billing::Recovery::InvalidOptions, "INCLUDE_REVIEW must be 0 or 1" unless %w[0 1].include?(review)
        recovery = Billing::Recovery.new(kind:, limit: Integer(ENV.fetch("LIMIT", "25"), 10),
          min_age_minutes: Integer(ENV.fetch("MIN_AGE_MINUTES", "10"), 10), ids: ids || [], include_review: review == "1")
        plan = recovery.plan
        puts "Billing recovery plan: #{plan.to_h.to_json}"
        unless ENV["CONFIRM"] == "recover"
          puts "Dry run: 0 provider requests, no writes or jobs. Set CONFIRM=recover and MAX_REQUESTS=N to execute."
          next
        end
        raise Billing::Recovery::InvalidOptions, "MAX_REQUESTS is required for execution" unless ENV.key?("MAX_REQUESTS")
        result = recovery.execute(plan, max_requests: Integer(ENV.fetch("MAX_REQUESTS"), 10))
        puts "Billing recovery result: #{result.except(:failed).to_json}"
        abort "Billing recovery has failed/review items; inspect local status before retrying." if result.fetch(:failed)
      rescue ArgumentError
        abort "Billing recovery refused: numeric options and comma-separated IDs must be integers."
      rescue Billing::Recovery::InvalidOptions, Billing::Recovery::BudgetExceeded => error
        abort "Billing recovery refused: #{error.message}"
      rescue Billing::Configuration::Unavailable
        abort "Billing recovery refused: billing mode, prices and transport secrets must be configured."
      end
    end
  end
end
