# frozen_string_literal: true

namespace :pipeline do
  desc "Queue pending filings again (default: those pending over 60 minutes). One SEC request per filing not yet archived"
  task :requeue_pending, %i[minutes] => :environment do |_, args|
    cutoff = (args[:minutes] || 60).to_i.minutes.ago
    accessions = Filing.form4.pending.where(created_at: ...cutoff).pluck(:accession_no)

    accessions.each { |accession_no| ParseForm4Job.perform_later(accession_no) }
    puts "Queued #{accessions.size} pending filings."
  end

  desc "Queue failed filings again. Archived filings are re-parsed without contacting the SEC"
  task retry_failures: :environment do
    accessions = Filing.form4.failed.pluck(:accession_no)

    accessions.each { |accession_no| ParseForm4Job.perform_later(accession_no) }
    puts "Queued #{accessions.size} failed filings."
  end

  desc "Process one filing now, in this process: pipeline:process[0001104659-26-112212]"
  task :process, %i[accession_no] => :environment do |_, args|
    abort "Usage: rake pipeline:process[ACCESSION]" if args[:accession_no].blank?

    ParseForm4Job.perform_now(args[:accession_no])
    filing = Filing.find_by(accession_no: args[:accession_no])
    puts filing ? "#{filing.accession_no}: #{filing.parse_status}, #{filing.insider_transactions.count} transaction rows" : "No such filing."
    puts ParseFailure.unresolved.find_by(accession_no: args[:accession_no])&.error
  end
end
