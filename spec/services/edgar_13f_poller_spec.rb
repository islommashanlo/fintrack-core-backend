# frozen_string_literal: true

require "rails_helper"

RSpec.describe Edgar13fPoller do
  subject(:poller) { described_class.new(search: Edgar::FullTextSearch.new(client: unthrottled_sec_client)) }

  let(:date) { Date.new(2026, 9, 30) }

  it "polls each 13F form and queues the corresponding parse jobs" do
    Filing::FORM13F_TYPES.each do |form|
      stub_request(:get, search_url(date.iso8601, form:)).to_return(
        body: search_body(total: 1, accessions: [ "0002135539-26-000001" ], form:, date: date.iso8601)
      )
    end

    added = poller.poll([ date ])

    expect(added).to eq([ "0002135539-26-000001" ])
    expect(Filing.sole).to have_attributes(form_type: "13F-HR")
    expect(ParseForm13fJob).to have_been_enqueued.once
  end

  it "does not advance the family success marker when a later form fails" do
    previous = 1.hour.ago.change(usec: 0)
    FilingsIntel.redis.call("SET", described_class::LAST_SUCCESS_KEY, previous.iso8601)
    stub_request(:get, search_url(date.iso8601, form: "13F-HR")).to_return(body: search_body(total: 0, accessions: []))
    stub_request(:get, search_url(date.iso8601, form: "13F-HR/A")).to_return(status: 500)

    expect { poller.poll([ date ]) }.to raise_error(SecClient::TransientError)
    expect(described_class.last_success_at).to eq(previous)
  end

  it "records family success only after every form returns" do
    Filing::FORM13F_TYPES.each do |form|
      stub_request(:get, search_url(date.iso8601, form:)).to_return(body: search_body(total: 0, accessions: []))
    end
    freeze_time do
      expect(described_class.last_success_at).to be_nil
      poller.poll([ date ])
      expect(described_class.last_success_at).to eq(Time.current.change(usec: 0))
    end
  end
end
