# frozen_string_literal: true

module Edgar
  # The daily master index (/Archives/edgar/daily-index/), used for backfills and to
  # reconcile what the live poller found.
  #
  # Checked against live files on 2026-10-02:
  # - rows are `CIK|Company Name|Form Type|YYYYMMDD|edgar/data/<cik>/<accession>.txt`;
  # - a filing appears once per associated CIK (issuer and each owner), so rows repeat;
  # - there is no file for weekends and holidays, and asking for one returns 403, not 404.
  #   The quarter's directory listing is therefore used to see which days exist.
  class DailyIndex
    class MalformedError < StandardError; end

    BASE_URL = "https://www.sec.gov/Archives/edgar/daily-index"
    HEADER = "CIK|Company Name|Form Type|Date Filed|File Name"
    ROW = %r{\A(?<cik>\d+)\|.*\|(?<form>[^|]+)\|(?<date>\d{8})\|edgar/data/\d+/(?<accession>\d{10}-\d{2}-\d{6})\.txt\z}

    def self.parse(text, forms: Filing::FORM4_TYPES)
      lines = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.lines(chomp: true)
      raise MalformedError, "index has no column header" unless lines.include?(HEADER)

      lines.filter_map { |line| ref(line.match(ROW), forms) }.uniq(&:accession_no)
    end

    def self.ref(match, forms)
      return nil unless match && forms.include?(match[:form])

      FilingRef.new(
        accession_no: match[:accession],
        cik: Cik.normalize(match[:cik]),
        form_type: match[:form],
        filed_on: Date.strptime(match[:date], "%Y%m%d")
      )
    end
    private_class_method :ref

    def initialize(client: nil, forms: Filing::FORM4_TYPES, lane: :form4)
      @client = client || SecClient.new(lane:)
      @forms = forms
      @listings = {}
    end

    # True when EDGAR published an index for that day.
    def available?(date)
      listing(date).include?(file_name(date))
    end

    def fetch(date)
      self.class.parse(@client.get("#{quarter_url(date)}/#{file_name(date)}"), forms: @forms)
    end

    private

    def listing(date)
      @listings[quarter_url(date)] ||= begin
        items = @client.get_json("#{quarter_url(date)}/index.json").dig("directory", "item")
        raise MalformedError, "directory listing has no items" unless items.is_a?(Array)

        items.to_set { |item| item["name"] }
      end
    end

    def quarter_url(date)
      "#{BASE_URL}/#{date.year}/QTR#{(date.month - 1) / 3 + 1}"
    end

    def file_name(date)
      "master.#{date.strftime('%Y%m%d')}.idx"
    end
  end
end
