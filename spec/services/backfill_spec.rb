# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backfill do
  subject(:backfill) { described_class.new(index: Edgar::DailyIndex.new(client: unthrottled_sec_client)) }

  let(:quarter_url) { "https://www.sec.gov/Archives/edgar/daily-index/2026/QTR3" }
  let(:day) { Date.new(2026, 9, 30) }
  let!(:listing) do
    stub_request(:get, "#{quarter_url}/index.json").to_return(body: edgar_fixture("daily_index_listing.json"))
  end
  let!(:index_file) do
    stub_request(:get, "#{quarter_url}/master.20260930.idx").to_return(body: edgar_fixture("master.20260930.idx"))
  end

  it "registers the day's Form 4 filings and records the run" do
    run = backfill.run_day(day)

    expect(run).to have_attributes(day:, status: "done", filings_found: 16, filings_new: 16, error: nil)
    expect(run.finished_at).to be_present
    expect(Filing.pending.where(source: "daily_index").count).to eq(16)
    expect(ParseForm4Job).to have_been_enqueued.exactly(16).times
  end

  it "can be run again without adding or queueing anything" do
    backfill.run_day(day)

    expect { backfill.run_day(day) }.not_to change { [ Filing.count, enqueued_jobs.size, BackfillRun.count ] }
    expect(BackfillRun.sole).to have_attributes(status: "done", filings_found: 16, filings_new: 0)
  end

  it "only adds what the live poller had not already found" do
    FilingRegistrar.register(Edgar::DailyIndex.parse(edgar_fixture("master.20260930.idx")).first(10), source: "efts")

    expect(backfill.run_day(day)).to have_attributes(filings_found: 16, filings_new: 6)
  end

  it "marks a day with no index without requesting one" do
    run = backfill.run_day(Date.new(2026, 9, 26))

    expect(run).to have_attributes(status: "no_index", filings_found: 0)
    expect(index_file).not_to have_been_requested
  end

  it "records a failure on the run and carries on with the rest of a range" do
    stub_request(:get, "#{quarter_url}/master.20260929.idx").to_return(status: 500)
    allow(Rails.logger).to receive(:error)

    runs = backfill.run(from: Date.new(2026, 9, 29), to: day)

    expect(runs.map(&:status)).to eq(%w[failed done])
    expect(runs.first.error).to match(/\ASecClient::TransientError/)
    expect(listing).to have_been_requested.once
  end
end
