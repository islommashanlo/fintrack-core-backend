# frozen_string_literal: true

namespace :validate do
  desc "Health checks over ingested data. Exits 1 if any check FAILs"
  task report: :environment do
    report = ValidationReport.new

    report.checks.each do |check|
      puts "#{check.level.to_s.upcase.ljust(4)}  #{check.title}"
      puts "      #{check.detail}" if check.detail
    end

    counts = report.checks.map(&:level).tally
    puts "", "#{counts.fetch(:fail, 0)} FAIL, #{counts.fetch(:warn, 0)} WARN, #{counts.fetch(:pass, 0)} PASS"
    exit 1 if report.failed?
  end

  desc "Compare our Form 4 filings for a day with EDGAR's daily index (2 SEC requests): validate:crosscheck[2026-09-30]"
  task :crosscheck, %i[day] => :environment do |_, args|
    abort "Usage: rake validate:crosscheck[YYYY-MM-DD]" if args[:day].blank?

    result = IndexCrosscheck.new.call(Date.iso8601(args[:day]))
    unless result.index_available
      puts "EDGAR has no daily index for #{result.day} (weekend or holiday). We hold #{result.in_database} filings dated that day."
      next
    end

    puts "#{result.day}: #{result.in_index} Form 4 filings in the index, #{result.in_database} dated that day in the database"
    puts "Missing from the database (#{result.missing.size}): #{result.missing.first(20).join(', ').presence || 'none'}"
    puts "Dated that day but not in its index (#{result.unexpected.size}): #{result.unexpected.first(20).join(', ').presence || 'none'}"
    exit 1 unless result.consistent?
  end
end
