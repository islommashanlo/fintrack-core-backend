# frozen_string_literal: true

# Fetches, archives, parses and ingests one Form 4.
#
# Invariant 6: only transient failures (network, 5xx, rate limiting) are retried, at most
# three times. Everything else is deterministic, so it is recorded in parse_failures on
# the first attempt and the job ends.
class ParseForm4Job < ApplicationJob
  MAX_RETRIES = 3

  queue_as :sec_live_form4

  retry_on SecClient::TransientError, attempts: MAX_RETRIES + 1, wait: :polynomially_longer do |job, error|
    job.record_failure(job.arguments.first, error)
  end

  def perform(accession_no)
    filing = Filing.find_by(accession_no:)
    return record_failure(accession_no, "unknown filing: no filings row for this accession number") if filing.nil?

    Form4Pipeline.new.process(filing)
  rescue SecClient::TransientError
    raise
  rescue StandardError => e
    record_failure(accession_no, e)
  end

  def record_failure(accession_no, error)
    ParseFailure.record!(accession_no, error)
    Filing.where(accession_no:).update_all(parse_status: "failed", updated_at: Time.current)
  end
end
