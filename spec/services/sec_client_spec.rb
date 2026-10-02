# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecClient do
  let(:url) { "https://www.sec.gov/Archives/edgar/data/1/0000000001-26-000001.txt" }
  let(:limiter) { instance_double(SecRateLimiter, acquire: 0) }
  let(:sleeps) { [] }
  let(:client) { described_class.new(limiter: limiter, sleeper: ->(seconds) { sleeps << seconds }) }

  it "returns the body and identifies itself with the contact address from ENV" do
    stub = stub_request(:get, url)
           .with(headers: { "User-Agent" => "FilingsIntel specs@example.com" })
           .to_return(status: 200, body: "filing text")

    expect(client.get(url)).to eq("filing text")
    expect(stub).to have_been_requested.once
  end

  it "refuses to start without a contact address" do
    expect { described_class.new(email: nil) }.to raise_error(SecClient::ConfigurationError)
    expect { described_class.new(email: " ") }.to raise_error(SecClient::ConfigurationError)
  end

  it "refuses URLs that are not SEC hosts over https, without making a request" do
    [ "https://example.com/x", "http://www.sec.gov/x", "https://www.sec.gov.evil.test/x" ].each do |bad|
      expect { client.get(bad) }.to raise_error(ArgumentError)
    end
    expect(limiter).not_to have_received(:acquire)
    expect(a_request(:any, //)).not_to have_been_made
  end

  it "takes a rate-limiter slot before every request, including retries" do
    stub_request(:get, url).to_return({ status: 429 }, { status: 503 }, { status: 200, body: "ok" })

    client.get(url)

    expect(limiter).to have_received(:acquire).exactly(3).times
  end

  it "waits for the number of seconds in Retry-After before retrying" do
    stub_request(:get, url).to_return(
      { status: 429, headers: { "Retry-After" => "7" } },
      { status: 200, body: "ok" }
    )

    expect(client.get(url)).to eq("ok")
    expect(sleeps).to eq([ 7 ])
  end

  it "understands Retry-After given as an HTTP date" do
    stub_request(:get, url).to_return(
      { status: 503, headers: { "Retry-After" => 30.seconds.from_now.httpdate } },
      { status: 200, body: "ok" }
    )

    client.get(url)

    expect(sleeps.first).to be_between(28, 31)
  end

  it "backs off 1s, 2s, 4s when the SEC gives no Retry-After, then gives up" do
    stub = stub_request(:get, url).to_return(status: 429)

    expect { client.get(url) }.to raise_error(SecClient::TransientError) { |e| expect(e.status).to eq(429) }
    expect(sleeps).to eq([ 1, 2, 4 ])
    expect(stub).to have_been_requested.times(4)
  end

  it "does not sleep through an unreasonably long Retry-After" do
    stub = stub_request(:get, url).to_return(status: 429, headers: { "Retry-After" => "3600" })

    expect { client.get(url) }.to raise_error(SecClient::TransientError)
    expect(sleeps).to be_empty
    expect(stub).to have_been_requested.once
  end

  it "raises a transient error for other 5xx responses without retrying itself" do
    stub = stub_request(:get, url).to_return(status: 500)

    expect { client.get(url) }.to raise_error(SecClient::TransientError)
    expect(stub).to have_been_requested.once
  end

  it "raises a transient error for timeouts and connection failures" do
    stub_request(:get, url).to_timeout
    expect { client.get(url) }.to raise_error(SecClient::TransientError)

    stub_request(:get, url).to_raise(Faraday::ConnectionFailed.new("reset"))
    expect { client.get(url) }.to raise_error(SecClient::TransientError)
  end

  it "raises deterministic errors for 404 and other 4xx responses" do
    stub_request(:get, url).to_return(status: 404)
    expect { client.get(url) }.to raise_error(SecClient::NotFound)

    stub_request(:get, url).to_return(status: 403)
    expect { client.get(url) }.to raise_error(SecClient::RequestError) { |e| expect(e.status).to eq(403) }
  end

  it "parses JSON responses and rejects non-JSON ones" do
    efts = "https://efts.sec.gov/LATEST/search-index?q=&forms=4"
    stub_request(:get, efts).to_return(status: 200, body: '{"hits":{"total":{"value":3}}}')
    expect(client.get_json(efts).dig("hits", "total", "value")).to eq(3)

    stub_request(:get, efts).to_return(status: 200, body: "<html>blocked</html>")
    expect { client.get_json(efts) }.to raise_error(SecClient::RequestError)
  end
end
