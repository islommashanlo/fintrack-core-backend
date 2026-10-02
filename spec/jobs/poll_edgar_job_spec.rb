# frozen_string_literal: true

require "rails_helper"

RSpec.describe PollEdgarJob do
  it "registers new filings and queues them for parsing" do
    travel_to Time.utc(2026, 9, 30, 18, 0) do
      stub_request(:get, search_url("2026-09-30")).to_return(body: edgar_fixture("full_text_search_form4.json"))
      stub_request(:get, search_url("2026-09-29")).to_return(body: search_body(total: 0, accessions: []))

      described_class.perform_now

      expect(Filing.pending.pluck(:form_type).tally).to eq("4" => 4, "4/A" => 1)
      expect(ParseForm4Job).to have_been_enqueued.exactly(5).times
    end
  end

  it "logs a failed poll and leaves it to the next run instead of retrying" do
    stub_request(:get, /efts\.sec\.gov/).to_return(status: 500)
    allow(Rails.logger).to receive(:warn)

    expect { described_class.perform_now }.not_to raise_error

    expect(Rails.logger).to have_received(:warn).with(/EDGAR poll failed: SecClient::TransientError/)
    expect(enqueued_jobs).to be_empty
    expect(EdgarPoller.last_success_at).to be_nil
    expect(described_class.sidekiq_options_hash["retry"]).to eq(0)
  end
end
