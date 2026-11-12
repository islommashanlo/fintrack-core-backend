# frozen_string_literal: true

namespace :archives do
  desc "Read-only archive metadata verification, at most 500 filings: archives:verify[limit,after_id,filing_ceiling]"
  task :verify, %i[limit after_id filing_ceiling] => :environment do |_, args|
    begin
      result = ArchiveVerification.new(limit: args[:limit] || 100, after_id: args[:after_id] || 0,
        filing_ceiling: args[:filing_ceiling]).call
    rescue ArgumentError => error
      abort error.message
    end
    result.fetch(:documents).each do |document|
      level = document.fetch("status") == "present" ? "PASS" : "FAIL"
      puts "#{level}  #{document.fetch('accession_no')} #{document.fetch('kind')}: #{document.fetch('status')}"
    end
    puts JSON.generate(result.except(:documents))
    exit 1 if result.fetch(:status_counts).any? { |status, count| status != "present" && count.positive? }
  end
end
