# frozen_string_literal: true

require "rails_helper"

RSpec.describe Edgar::FullTextSearch do
  subject(:search) { described_class.new(client: unthrottled_sec_client) }

  let(:date) { Date.new(2026, 9, 30) }

  it "reads a real response: one ref per filing, originals and amendments together" do
    stub_request(:get, search_url("2026-09-30")).to_return(body: edgar_fixture("full_text_search_form4.json"))

    page = search.page(form: "4", date:)

    expect(page.total).to eq(5)
    expect(page.hit_count).to eq(5)
    expect(page.refs.first).to eq(
      Edgar::FilingRef.new(accession_no: "0002148361-26-000004", cik: "0002148361", form_type: "4", filed_on: date)
    )
    expect(page.refs.map(&:form_type)).to eq(%w[4 4 4 4 4/A])
    expect(page.refs.last.accession_no).to eq("0001901839-26-000005")
  end

  it "asks for later pages with from=N" do
    request = stub_request(:get, search_url("2026-09-30", from: 100))
              .to_return(body: search_body(total: 101, accessions: accessions(101..101)))

    expect(search.page(form: "4", date:, from: 100).refs.size).to eq(1)
    expect(request).to have_been_requested.once
  end

  it "raises when the response is not the shape it expects" do
    stub_request(:get, search_url("2026-09-30")).to_return(body: '{"message":"Forbidden"}')
    expect { search.page(form: "4", date:) }.to raise_error(described_class::UnexpectedResponse, /no hits or total/)

    broken = { "hits" => { "total" => { "value" => 1 }, "hits" => [ { "_source" => { "adsh" => "x" } } ] } }.to_json
    stub_request(:get, search_url("2026-09-30")).to_return(body: broken)
    expect { search.page(form: "4", date:) }.to raise_error(described_class::UnexpectedResponse, /unreadable search hit/)
  end
end
