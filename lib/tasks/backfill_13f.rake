# frozen_string_literal: true

namespace :backfill do
  desc "Dry-run or execute a 13F daily-index backfill; execution requires confirm"
  task "13f", %i[from to confirm] => :environment do |_, args|
    abort "Usage: rake backfill:13f[FROM,TO,confirm]" if args[:from].blank? || args[:to].blank?

    confirmed = args[:confirm].to_s.casecmp("confirm").zero?
    abort "FORM13F_VALUE_UNIT is no longer supported; use accession-scoped config/form13f_value_units.yml." if confirmed && ENV["FORM13F_VALUE_UNIT"].present?
    from = Date.iso8601(args[:from])
    to = Date.iso8601(args[:to])
    ciks = ENV["CIKS"].to_s.split(",").filter_map { |cik| Cik.normalize(cik) rescue nil }
    ciks = nil if ciks.empty?
    backfill = Form13fBackfill.new
    plan = backfill.plan(from:, to:, ciks:)

    puts "13F backfill #{from} to #{to}: #{plan.refs.size} filings, " \
         "#{plan.request_count} SEC requests planned (#{plan.discovery_requests} discovery, " \
         "#{plan.document_requests} document)."

    next unless confirmed

    policy = Form13fValueUnitPolicy.load
    value_units = plan.refs.reject { |ref| ref.form_type == "13F-NT" }.to_h { |ref| [ ref.accession_no, policy.unit_for(ref.accession_no, filed_on: ref.filed_on) ] }
    runs = backfill.execute(plan, value_units:)
    puts "Executed #{runs.size} daily-index runs; queued #{runs.sum(&:filings_new)} new 13F filings."
  end
end
