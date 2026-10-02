# frozen_string_literal: true

require "rails_helper"

RSpec.describe EdgarPoller do
  subject(:poller) { described_class.new(search: Edgar::FullTextSearch.new(client: unthrottled_sec_client)) }

  let(:date) { Date.new(2026, 9, 30) }

  def stub_page(total:, range:, from: nil)
    stub_request(:get, search_url(date.iso8601, from:)).to_return(body: search_body(total:, accessions: accessions(range)))
  end

  it "registers every filing of the day, reading all pages" do
    stub_page(total: 250, range: 1..100)
    second = stub_page(total: 250, range: 101..200, from: 100)
    third = stub_page(total: 250, range: 201..250, from: 200)

    added = poller.poll([ date ])

    expect(added.size).to eq(250)
    expect(Filing.pending.where(source: "efts").count).to eq(250)
    expect(enqueued_jobs.size).to eq(250)
    expect(second).to have_been_requested.once
    expect(third).to have_been_requested.once
  end

  it "makes one request and changes nothing when the day's total has not moved" do
    first_page = stub_page(total: 3, range: 1..3)
    poller.poll([ date ])

    expect { expect(poller.poll([ date ])).to be_empty }.not_to change { [ Filing.count, enqueued_jobs.size ] }
    expect(first_page).to have_been_requested.twice
  end

  it "reads the day again when the total grows, registering only what is new" do
    stub_page(total: 3, range: 1..3)
    poller.poll([ date ])

    stub_page(total: 5, range: 1..5)

    expect(poller.poll([ date ])).to eq(accessions(4..5))
    expect(Filing.count).to eq(5)
  end

  it "does not remember the total if it could not read every page" do
    stub_page(total: 150, range: 1..100)
    empty_page = stub_request(:get, search_url(date.iso8601, from: 100)).to_return(body: search_body(total: 150, accessions: []))

    2.times { poller.poll([ date ]) }

    expect(empty_page).to have_been_requested.twice
    expect(Filing.count).to eq(100)
  end

  it "polls today and yesterday in EDGAR's time zone by default" do
    # 02:00 UTC on 1 October is still 30 September in New York.
    travel_to Time.utc(2026, 10, 1, 2, 0) do
      today = stub_request(:get, search_url("2026-09-30")).to_return(body: search_body(total: 0, accessions: []))
      yesterday = stub_request(:get, search_url("2026-09-29")).to_return(body: search_body(total: 0, accessions: []))

      poller.poll

      expect(today).to have_been_requested.once
      expect(yesterday).to have_been_requested.once
    end
  end

  it "records when it last succeeded" do
    stub_page(total: 0, range: [])

    expect(described_class.last_success_at).to be_nil
    freeze_time do
      poller.poll([ date ])
      expect(described_class.last_success_at).to eq(Time.current.change(usec: 0))
    end
  end

  it "does not record success when the search fails" do
    stub_request(:get, search_url(date.iso8601)).to_return(status: 500)

    expect { poller.poll([ date ]) }.to raise_error(SecClient::TransientError)
    expect(described_class.last_success_at).to be_nil
  end
end
