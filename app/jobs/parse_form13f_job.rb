# frozen_string_literal: true

# Fetches, archives, parses and ingests one 13F filing.
class ParseForm13fJob < ApplicationJob
  MAX_RETRIES = 3

  queue_as :sec_live_13f

  retry_on SecClient::TransientError, attempts: MAX_RETRIES + 1, wait: :polynomially_longer do |job, error|
    job.record_failure(job.arguments.first, error)
  end

  def perform(accession_no, value_unit: ENV["FORM13F_VALUE_UNIT"])
    filing = Filing.find_by(accession_no:)
    return record_failure(accession_no, "unknown filing: no filings row for this accession number") if filing.nil?

    Form13fPipeline.new(value_unit:).process(filing)
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
