# frozen_string_literal: true

namespace :backfill do
  desc "13F backfill progress per day and parse status"
  task "13f_status" => :environment do
    statuses = Filing.form13f.where.not(filed_on: nil).group(:filed_on, :parse_status).count
    rows = BackfillRun.order(:day).map do |run|
      {
        "day" => run.day,
        "status" => run.status,
        "found" => run.filings_found,
        "new" => run.filings_new,
        "parsed" => statuses.fetch([ run.day, "parsed" ], 0),
        "pending" => statuses.fetch([ run.day, "pending" ], 0),
        "failed" => statuses.fetch([ run.day, "failed" ], 0),
        "error" => run.error.to_s.truncate(60).presence
      }
    end

    puts TextTable.render(rows, { "Day" => "day", "Run" => "status", "In index" => "found", "New" => "new",
                                  "Parsed" => "parsed", "Pending" => "pending", "Failed" => "failed", "Error" => "error" })
    puts "", "All 13F filings: #{Filing.form13f.group(:parse_status).count.map { |status, n| "#{n} #{status}" }.join(', ').presence || 'none'}"
  end
end
