# frozen_string_literal: true

namespace :backfill do
  desc "Register Form 4 filings from the daily index: backfill:run[2026-09-01,2026-09-30]"
  task :run, %i[from to] => :environment do |_, args|
    abort "Usage: rake backfill:run[YYYY-MM-DD,YYYY-MM-DD]" if args[:from].blank?

    from = Date.iso8601(args[:from])
    to = Date.iso8601(args[:to].presence || args[:from])
    abort "The range ends before it starts" if to < from

    puts "Backfilling #{from} to #{to}. Each indexed day costs one SEC request, then one per new filing as jobs run."
    Backfill.new.run(from:, to:).each do |run|
      puts "#{run.day}  #{run.status.ljust(8)}  found #{run.filings_found.to_s.rjust(5)}  new #{run.filings_new.to_s.rjust(5)}  #{run.error}"
    end
    puts "Parsing happens in Sidekiq. Watch progress with `rake backfill:status`."
  end

  desc "Backfill progress per day and parse status of the filings found"
  task status: :environment do
    statuses = Filing.form4.where.not(filed_on: nil).group(:filed_on, :parse_status).count
    rows = BackfillRun.order(:day).map do |run|
      { "day" => run.day, "status" => run.status, "found" => run.filings_found, "new" => run.filings_new,
        "parsed" => statuses.fetch([ run.day, "parsed" ], 0), "pending" => statuses.fetch([ run.day, "pending" ], 0),
        "failed" => statuses.fetch([ run.day, "failed" ], 0), "error" => run.error.to_s.truncate(60).presence }
    end

    puts TextTable.render(rows, { "Day" => "day", "Run" => "status", "In index" => "found", "New" => "new",
                                  "Parsed" => "parsed", "Pending" => "pending", "Failed" => "failed", "Error" => "error" })
    puts "", "All Form 4 filings: #{Filing.form4.group(:parse_status).count.map { |status, n| "#{n} #{status}" }.join(', ').presence || 'none'}"
    puts "Parsed, pending and failed count filings dated that day, from any source."
  end
end
