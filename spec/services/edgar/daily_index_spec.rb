# frozen_string_literal: true

require "rails_helper"

RSpec.describe Edgar::DailyIndex do
  subject(:index) { described_class.new(client: unthrottled_sec_client) }

  let(:quarter_url) { "https://www.sec.gov/Archives/edgar/daily-index/2026/QTR3" }

  describe ".parse" do
    let(:refs) { described_class.parse(edgar_fixture("master.20260930.idx")) }

    it "keeps Form 4 and 4/A rows from a real index and ignores other forms" do
      expect(refs.map(&:form_type).tally).to eq("4" => 12, "4/A" => 4)
      expect(refs.find { |r| r.accession_no == "0001010178-26-000013" }).to eq(
        Edgar::FilingRef.new(accession_no: "0001010178-26-000013", cik: "0001010178", form_type: "4",
                             filed_on: Date.new(2026, 9, 30))
      )
    end

    it "lists a filing once even though the index repeats it for each associated CIK" do
      matches = refs.select { |r| r.accession_no == "0001437749-26-031545" }

      expect(matches.size).to eq(1)
      expect(matches.first.cik).to eq("0001001385")
    end

    it "can be asked for other form types" do
      expect(described_class.parse(edgar_fixture("master.20260930.idx"), forms: %w[424B2]).size).to eq(6)
    end

    it "rejects text that is not an index, such as an error page" do
      expect { described_class.parse("<Error><Code>AccessDenied</Code></Error>") }
        .to raise_error(described_class::MalformedError)
    end
  end

  describe "#available?" do
    before do
      stub_request(:get, "#{quarter_url}/index.json").to_return(body: edgar_fixture("daily_index_listing.json"))
    end

    it "uses the directory listing, since a missing index answers 403 like a block would" do
      expect(index.available?(Date.new(2026, 9, 30))).to be(true)
      expect(index.available?(Date.new(2026, 9, 26))).to be(false) # a Saturday
      expect(a_request(:get, "#{quarter_url}/index.json")).to have_been_made.once
      expect(a_request(:get, %r{master\.\d+\.idx})).not_to have_been_made
    end
  end

  describe "#fetch" do
    it "requests the day's master index from the right quarter" do
      stub_request(:get, "#{quarter_url}/master.20260930.idx").to_return(body: edgar_fixture("master.20260930.idx"))
      expect(index.fetch(Date.new(2026, 9, 30)).size).to eq(16)

      first_quarter = stub_request(:get, "https://www.sec.gov/Archives/edgar/daily-index/2026/QTR1/master.20260102.idx")
                      .to_return(body: edgar_fixture("master.20260930.idx"))
      fourth_quarter = stub_request(:get, "https://www.sec.gov/Archives/edgar/daily-index/2025/QTR4/master.20251231.idx")
                       .to_return(body: edgar_fixture("master.20260930.idx"))
      index.fetch(Date.new(2026, 1, 2))
      index.fetch(Date.new(2025, 12, 31))
      expect(first_quarter).to have_been_requested
      expect(fourth_quarter).to have_been_requested
    end
  end
end
