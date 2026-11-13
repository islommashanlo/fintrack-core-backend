# frozen_string_literal: true

require "rails_helper"

RSpec.describe InAppInboxChannel, type: :channel do
  let(:session_record) { Session.create!(user: create(:user)) }
  before do
    stub_connection(current_session: session_record)
    connection.define_singleton_method(:session_active?) { true }
    connection.define_singleton_method(:close) { |**_options| }
  end

  it "subscribes only to the authenticated account stream" do
    subscribe
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(InAppInboxRealtime.stream(session_record.user_id))
    expect(subscription.streams.size).to eq(1)
    expect(described_class.action_methods).not_to include("refresh", "check_session")
  end

  it "rejects client-selected users, streams and expired sessions" do
    subscribe(user_id: create(:user, email_address: "other@example.com").id)
    expect(subscription).to be_rejected
    subscribe(stream: InAppInboxRealtime.stream(session_record.user_id))
    expect(subscription).to be_rejected
    allow(connection).to receive(:session_active?).and_return(false)
    subscribe
    expect(subscription).to be_rejected
  end

  it "sends only repeatable refresh hints and suppresses all revoked-session messages" do
    subscribe
    2.times { subscription.send(:refresh) }
    expect(transmissions).to eq([ InAppInboxRealtime::HINT.stringify_keys ] * 2)
    allow(connection).to receive(:session_active?).and_return(false)
    expect(connection).to receive(:close).with(reconnect: false)
    subscription.send(:refresh)
    expect(transmissions.size).to eq(2)
    expect(subscription).not_to have_streams
  end

  it "checks idle session revocation periodically and stops the stream" do
    subscribe
    expect(described_class.periodic_timers.sole.last).to eq(every: 15.seconds)
    allow(connection).to receive(:session_active?).and_return(false)
    expect(connection).to receive(:close).with(reconnect: false)
    subscription.send(:check_session)
    expect(subscription).not_to have_streams
  end
end
