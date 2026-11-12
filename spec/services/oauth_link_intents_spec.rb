# frozen_string_literal: true

require "rails_helper"

RSpec.describe OauthLinkIntents do
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:user) { create(:user, password: "password123") }
  let(:session) { user.sessions.create! }

  def issue(password = "password123")
    described_class.issue(user:, session:, current_password: password)
  end

  def consume(result, **overrides)
    described_class.consume(user:, session:, state: result.state, nonce: result.nonce, **overrides)
  end

  it "requires password confirmation and stores only random state/nonce digests" do
    expect { issue("wrong") }.to raise_error(described_class::ReauthenticationRequired)
    expect(OauthLinkIntent.count).to eq(0)
    result = issue
    record = OauthLinkIntent.sole
    expect(record.expires_at).to eq(5.minutes.from_now)
    expect(record.attributes.values).not_to include(result.state, result.nonce)
    expect(result.state.length).to eq(43)
    expect(result.nonce).not_to eq(result.state)
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter({ "state" => result.state, "nonce" => result.nonce }).values).to eq([ "[FILTERED]", "[FILTERED]" ])
    expect(OauthIdentity.count).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "consumes valid intent once and rejects replay and incorrect nonces without consuming it" do
    result = issue
    expect { consume(result, nonce: SecureRandom.urlsafe_base64(32)) }.to raise_error(described_class::Invalid)
    expect(OauthLinkIntent.sole.consumed_at).to be_nil
    expect(consume(result).consumed_at).to eq(Time.current)
    expect { consume(result) }.to raise_error(described_class::Invalid)
  end

  it "replaces prior intent in the same session without growing rows" do
    first = issue
    second = issue
    expect(OauthLinkIntent.count).to eq(1)
    expect { consume(first) }.to raise_error(described_class::Invalid)
    expect(consume(second)).to be_persisted
  end

  it "rejects expired and malformed state at the expiry boundary" do
    result = issue
    [ nil, "", [], "x" * 500 ].each do |state|
      expect { consume(result, state:) }.to raise_error(described_class::Invalid)
    end
    travel 5.minutes
    expect { consume(result) }.to raise_error(described_class::Invalid)
  end

  it "binds intents to the original account and active session and cascades bulk revocation" do
    result = issue
    other_session = user.sessions.create!
    expect { consume(result, session: other_session) }.to raise_error(described_class::Invalid)
    other = create(:user, email_address: "other@example.com")
    expect { consume(result, user: other) }.to raise_error(described_class::Invalid)
    user.sessions.delete_all
    expect(OauthLinkIntent.count).to eq(0)
    expect { consume(result) }.to raise_error(described_class::Invalid)
  end

  it "rejects stale sessions even if an intent has not expired" do
    session.update!(created_at: 31.days.ago)
    expect { issue }.to raise_error(described_class::Invalid)
  end
end
