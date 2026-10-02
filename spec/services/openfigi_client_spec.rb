# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenfigiClient do
  let(:url) { "https://api.openfigi.com/v3/mapping" }

  it "maps CUSIPs in batches without using the SEC client" do
    stub_request(:post, url)
      .with { |request| JSON.parse(request.body) == [ { "idType" => "ID_CUSIP", "idValue" => "037833100" } ] }
      .to_return(
        status: 200,
        body: [ { "data" => [ { "figi" => "BBG000B9XRY4", "ticker" => "AAPL", "name" => "APPLE INC" } ] } ].to_json
      )

    result = described_class.new(api_key: nil).map([ "037833100", "bad" ]).sole

    expect(result).to have_attributes(cusip: "037833100", status: "mapped")
    expect(a_request(:post, url)).to have_been_requested.once
  end

  it "raises a transient error for rate limits and service errors" do
    stub_request(:post, url).to_return(status: 429, body: "slow down")

    expect { described_class.new(api_key: nil).map([ "037833100" ]) }
      .to raise_error(described_class::TransientError)
  end
end
