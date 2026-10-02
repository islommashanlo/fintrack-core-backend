# frozen_string_literal: true

# Fetches, archives, parses and ingests one 13F filing.
class Form13fPipeline
  def initialize(client: nil, archive: FilingArchive.default, value_unit: nil)
    @client = client
    @archive = archive
    @value_unit = value_unit
  end

  def process(filing)
    report = filing.institutional_report
    if report && @archive.exist?(report.cover_raw_path)
      cover_path = report.cover_raw_path
      information_path = report.information_raw_path
      cover_xml = @archive.read(cover_path)
      information_xml = information_path && @archive.read(information_path)
    else
      directory = Form13fDirectoryIndex.parse(client.get(directory_url(filing)))
      unless directory.xml_documents?
        result = Form13fIngestor.skip!(filing:, reason: "pre_xml_information_table")
        EvaluateAlertsJob.perform_later(filing.id)
        return result
      end

      cover_document = directory.cover
      cover_path = archive_document(filing, cover_document.filename, client.get(document_url(filing, cover_document.filename)))
      cover_xml = @archive.read(cover_path)
      information_document = directory.information_table
      if information_document.nil? && filing.form_type != "13F-NT"
        raise Form13fDirectoryIndex::MalformedError, "13F-HR filing index has no information-table document"
      end

      if information_document
        information_path = archive_document(
          filing, information_document.filename, client.get(document_url(filing, information_document.filename))
        )
        information_xml = @archive.read(information_path)
      end
    end

    cover = Form13fCoverParser.parse(cover_xml)
    if information_xml
      holdings = Form13fInformationTableParser.parse(information_xml)
      raise Form13fIngestor::MismatchError, "13F-HR has no configured value unit" if @value_unit.nil?
    else
      holdings = []
    end

    Form13fIngestor.call(
      filing:, cover:, holdings:, value_unit: @value_unit,
      raw_paths: { cover: cover_path, information: information_path }
    )
    ParseFailure.resolve!(filing.accession_no)
    EvaluateAlertsJob.perform_later(filing.id)
    filing
  end

  private

  def archive_document(filing, filename, body)
    @archive.store_13f(
      manager_cik: filing.cik,
      year: filing.filed_on&.year || filing.period_of_report&.year || Time.current.year,
      accession_no: filing.accession_no,
      filename:,
      body:
    )
  end

  def directory_url(filing)
    "https://www.sec.gov/Archives/edgar/data/#{Cik.path_segment(filing.cik)}/#{filing.accession_no.delete('-')}/index.html"
  end

  def document_url(filing, filename)
    "https://www.sec.gov/Archives/edgar/data/#{Cik.path_segment(filing.cik)}/#{filing.accession_no.delete('-')}/#{filename}"
  end

  def client
    @client ||= SecClient.new(lane: :form13f)
  end
end
