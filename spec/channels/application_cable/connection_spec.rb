# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:session_record) { Session.create!(user: create(:user)) }
  before do
    allow(InAppInboxRealtime).to receive(:enabled?).and_return(true)
    cookies.signed[:session_id] = session_record.id
  end

  def open_connection(origin: "http://www.example.com", **options)
    connect(headers: { "Origin" => origin }, env: { "HTTP_HOST" => "www.example.com", "rack.url_scheme" => "http" }, **options)
  end

  it "authenticates only the signed active session, ignoring client account IDs" do
    open_connection(params: { user_id: create(:user, email_address: "other@example.com").id })
    expect(connection.current_session).to eq(session_record)
    expect(connection.session_active?).to be(true)
    session_record.destroy!
    expect(connection.session_active?).to be(false)
  end

  it "rejects unsigned, missing, expired and disabled connections" do
    cookies.signed[:session_id] = nil
    cookies[:session_id] = session_record.id
    expect { open_connection }.to have_rejected_connection
    cookies.signed[:session_id] = session_record.id
    session_record.update!(created_at: 31.days.ago)
    expect { open_connection }.to have_rejected_connection
    session_record.update!(created_at: Time.current)
    allow(InAppInboxRealtime).to receive(:enabled?).and_return(false)
    expect { open_connection }.to have_rejected_connection
  end

  it "requires an exact same-origin or configured frontend origin" do
    allow(Middleware::ApiCors).to receive(:origin).and_return("https://app.example.com")
    expect { open_connection(origin: "https://app.example.com") }.not_to raise_error
    [ nil, "null", "https://evil.example", "https://app.example.com.evil" ].each do |origin|
      expect { open_connection(origin:) }.to have_rejected_connection
    end
  end

  it "fails closed on connection throttling and unavailable rate limiting" do
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Limited.new(5))
    expect { open_connection }.to have_rejected_connection
    allow(ApiRateLimiter).to receive(:check!).and_raise(ApiRateLimiter::Unavailable)
    expect { open_connection }.to have_rejected_connection
  end

  it "rechecks expiry and transport disablement after connecting" do
    open_connection
    travel 31.days do
      expect(connection.session_active?).to be(false)
    end
    allow(InAppInboxRealtime).to receive(:enabled?).and_return(false)
    expect(connection.session_active?).to be(false)
  end
end
