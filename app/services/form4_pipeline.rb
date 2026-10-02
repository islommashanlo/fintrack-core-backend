# frozen_string_literal: true

# Takes one known filing from "pending" to "parsed": fetch (or reuse the archived copy),
# archive, parse, ingest.
class Form4Pipeline
  def initialize(client: nil, archive: FilingArchive.default)
    @client = client
    @archive = archive
  end

  def process(filing)
    submission = Edgar::Submission.parse(raw_for(filing))
    document = Form4Parser.parse(submission.ownership_xml)

    Form4Ingestor.call(filing:, document:, header: submission.header)
    ParseFailure.resolve!(filing.accession_no)
    EvaluateAlertsJob.perform_later(filing.id)
    filing
  end

  private

  # The archive is the source of truth once a filing has been fetched: re-processing
  # never goes back to the SEC.
  def raw_for(filing)
    return @archive.read(filing.raw_path) if @archive.exist?(filing.raw_path)

    body = client.get(filing.edgar_url)
    filing.update!(raw_path: @archive.store(filing.accession_no, body))
    body
  end

  def client
    @client ||= SecClient.new(lane: :form4)
  end
end
