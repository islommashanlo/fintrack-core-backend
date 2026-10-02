# frozen_string_literal: true

module SecStubs
  def edgar_fixture(name)
    Rails.root.join("spec/fixtures/edgar", name).read
  end

  # A real SecClient that does not wait for rate-limiter slots, for specs that make several requests.
  def unthrottled_sec_client
    SecClient.new(limiter: instance_double(SecRateLimiter, acquire: 0))
  end

  def search_url(date, from: nil, form: "4")
    url = "https://efts.sec.gov/LATEST/search-index?q=&forms=#{form}&dateRange=custom&startdt=#{date}&enddt=#{date}"
    from ? "#{url}&from=#{from}" : url
  end

  # A search response in the real shape, with made-up accession numbers.
  def search_body(total:, accessions:, form: "4", date: "2026-09-30")
    hits = accessions.map do |accession|
      { "_id" => "#{accession}:form4.xml",
        "_source" => { "adsh" => accession, "ciks" => [ "0001010178", "0000060086" ], "form" => form, "file_date" => date } }
    end

    { "hits" => { "total" => { "value" => total, "relation" => "eq" }, "hits" => hits } }.to_json
  end

  def accessions(range)
    range.map { |n| format("0001010178-26-%06d", n) }
  end
end

RSpec.configure do |config|
  config.include SecStubs
end
