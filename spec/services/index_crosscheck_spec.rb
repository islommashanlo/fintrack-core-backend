# frozen_string_literal: true

require "rails_helper"

RSpec.describe IndexCrosscheck do
  subject(:crosscheck) { described_class.new(index: Edgar::DailyIndex.new(client: unthrottled_sec_client)) }

  let(:quarter_url) { "https://www.sec.gov/Archives/edgar/daily-index/2026/QTR3" }
  let(:day) { Date.new(2026, 9, 30) }
  let(:refs) { Edgar::DailyIndex.parse(edgar_fixture("master.20260930.idx")) }

  before do
    stub_request(:get, "#{quarter_url}/index.json").to_return(body: edgar_fixture("daily_index_listing.json"))
    stub_request(:get, "#{quarter_url}/master.20260930.idx").to_return(body: edgar_fixture("master.20260930.idx"))
  end

  it "is consistent when we hold everything the index lists" do
    FilingRegistrar.register(refs, source: "efts")

    expect(crosscheck.call(day)).to have_attributes(in_index: 16, in_database: 16, missing: [], unexpected: [], consistent?: true)
  end

  it "names filings the index lists that we never registered" do
    FilingRegistrar.register(refs.drop(2), source: "efts")

    result = crosscheck.call(day)

    expect(result.missing).to match_array(refs.first(2).map(&:accession_no))
    expect(result).not_to be_consistent
  end

  it "does not call a filing missing just because we date it to another day" do
    FilingRegistrar.register(refs, source: "efts")
    Filing.find_by!(accession_no: refs.first.accession_no).update!(filed_on: day - 1)
    extra = create(:filing, filed_on: day)

    result = crosscheck.call(day)

    expect(result.missing).to be_empty
    expect(result.unexpected).to eq([ extra.accession_no ])
    expect(result).to be_consistent
  end

  it "reports a day EDGAR has no index for" do
    expect(crosscheck.call(Date.new(2026, 9, 26))).to have_attributes(index_available: false, consistent?: false)
  end
end
