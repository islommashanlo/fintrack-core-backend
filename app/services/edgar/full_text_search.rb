# frozen_string_literal: true

module Edgar
  # EDGAR full-text search (EFTS), used for live detection of new filings.
  #
  # Checked against live responses on 2026-10-02:
  # - `forms=4` matches the root form, so one query returns both 4 and 4/A;
  # - there is one hit per filing, and `hits.total.value` equalled that day's count in the daily index;
  # - pages hold 100 hits and `from=N` skips N;
  # - a hit carries the filing date only. The acceptance time comes from the filing itself.
  class FullTextSearch
    class UnexpectedResponse < StandardError; end

    ENDPOINT = "https://efts.sec.gov/LATEST/search-index"
    PAGE_SIZE = 100

    Page = Data.define(:total, :hit_count, :refs)

    def initialize(client: SecClient.new)
      @client = client
    end

    def page(form:, date:, from: 0)
      params = { q: "", forms: form, dateRange: "custom", startdt: date.iso8601, enddt: date.iso8601 }
      params[:from] = from if from.positive?

      body = @client.get_json("#{ENDPOINT}?#{URI.encode_www_form(params)}")
      hits = body.dig("hits", "hits")
      total = body.dig("hits", "total", "value")
      raise UnexpectedResponse, "search response has no hits or total" unless hits.is_a?(Array) && total.is_a?(Integer)

      Page.new(total:, hit_count: hits.size, refs: hits.map { |hit| ref(hit) })
    end

    private

    def ref(hit)
      source = hit.fetch("_source")

      FilingRef.new(
        accession_no: source.fetch("adsh"),
        cik: Cik.normalize(source.fetch("ciks").first),
        form_type: source.fetch("form"),
        filed_on: Date.iso8601(source.fetch("file_date"))
      )
    rescue KeyError, ArgumentError, NoMethodError => e
      raise UnexpectedResponse, "unreadable search hit: #{e.message}"
    end
  end
end
