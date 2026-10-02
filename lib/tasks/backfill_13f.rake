# frozen_string_literal: true

namespace :backfill do
  desc "Dry-run or execute a 13F daily-index backfill; execution requires confirm"
  task "13f", %i[from to confirm] => :environment do |_, args|
    abort "Usage: rake backfill:13f[FROM,TO,confirm]" if args[:from].blank? || args[:to].blank?

    from = Date.iso8601(args[:from])
    to = Date.iso8601(args[:to])
    ciks = ENV["CIKS"].to_s.split(",").filter_map { |cik| Cik.normalize(cik) rescue nil }
    ciks = nil if ciks.empty?
    backfill = Form13fBackfill.new
    plan = backfill.plan(from:, to:, ciks:)

    puts "13F backfill #{from} to #{to}: #{plan.refs.size} filings, " \
         "#{plan.request_count} SEC requests planned (#{plan.discovery_requests} discovery, " \
         "#{plan.document_requests} document)."

    confirmed = args[:confirm].to_s.casecmp("confirm").zero?
    next unless confirmed

    value_unit = ENV["FORM13F_VALUE_UNIT"]
    abort "Set FORM13F_VALUE_UNIT to execute a holdings backfill." if value_unit.blank?

    runs = backfill.execute(plan, value_unit:)
    puts "Executed #{runs.size} daily-index runs; queued #{runs.sum(&:filings_new)} new 13F filings."
  end
end
