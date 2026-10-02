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
end
