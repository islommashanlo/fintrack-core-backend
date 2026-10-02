# frozen_string_literal: true

namespace :validate13f do
  desc "Health checks over institutional 13F data. Exits 1 if any check FAILs"
  task report: :environment do
    report = Validation13fReport.new

    report.checks.each do |check|
      puts "#{check.level.to_s.upcase.ljust(4)}  #{check.title}"
      puts "      #{check.detail}" if check.detail
    end

    counts = report.checks.map(&:level).tally
    puts "", "#{counts.fetch(:fail, 0)} FAIL, #{counts.fetch(:warn, 0)} WARN, #{counts.fetch(:pass, 0)} PASS"
    exit 1 if report.failed?
  end
end
