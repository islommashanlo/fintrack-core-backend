# frozen_string_literal: true

module Edgar
  # A complete submission text file (<accession>.txt): an SGML header followed by every
  # document in the filing. Pure: text in, values out.
  #
  # Layout confirmed against real Form 4 filings fetched on 2026-10-02 (see spec/fixtures).
  class Submission
    class MalformedError < StandardError; end

    # EDGAR stamps acceptance in US Eastern time and gives no zone in the header.
    EDGAR_ZONE = ActiveSupport::TimeZone["America/New_York"]

    Header = Data.define(:accession_no, :form_type, :accepted_at, :filed_on, :period_of_report)

    def self.parse(text)
      new(text)
    end

    def initialize(text)
      @text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      raise MalformedError, "empty submission" if @text.strip.empty?
    end

    def header
      @header ||= Header.new(
        accession_no: field(/^ACCESSION NUMBER:\s*(\S+)/, "accession number"),
        form_type: field(/^CONFORMED SUBMISSION TYPE:\s*(\S+)/, "submission type"),
        accepted_at: parse_accepted_at(field(/<ACCEPTANCE-DATETIME>(\d{14})/, "acceptance datetime")),
        filed_on: parse_date(field(/^FILED AS OF DATE:\s*(\d{8})/, "filing date")),
        period_of_report: parse_date(@text[/^CONFORMED PERIOD OF REPORT:\s*(\d{8})/, 1])
      )
    end

    # The Form 3/4/5 XML document embedded in the submission.
    def ownership_xml
      xml = @text.scan(%r{<XML>\s*(.*?)\s*</XML>}m).flatten.find { |doc| doc.include?("<ownershipDocument") }
      raise MalformedError, "no ownership XML document in submission" if xml.nil?

      xml
    end

    private

    def field(pattern, name)
      @text[pattern, 1] || raise(MalformedError, "submission header has no #{name}")
    end

    def parse_accepted_at(digits)
      EDGAR_ZONE.strptime(digits, "%Y%m%d%H%M%S").utc
    rescue ArgumentError
      raise MalformedError, "unreadable acceptance datetime: #{digits}"
    end

    def parse_date(digits)
      digits && Date.strptime(digits, "%Y%m%d")
    rescue Date::Error
      raise MalformedError, "unreadable date in header: #{digits}"
    end
  end
end
