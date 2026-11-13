# frozen_string_literal: true

require "rails_helper"

RSpec.describe "In-app realtime update boundaries" do
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user) }
  let(:follow) { create(:follow, user:, skip_default_alert_rule: true) }

  before do
    allow(InAppInboxRealtime).to receive(:enabled?).and_return(true)
    allow(InAppInboxRealtime).to receive(:after_commit).and_call_original
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    rule = AlertRule.create!(follow:, channel: "in_app", event_type: "new_filing", active: true)
    rule.setting.update!(enabled_at: 1.day.ago)
  end

  def match
    filing = create(:filing, issuer_ticker: "ACME", filed_at: Time.current)
    InAppNotificationMatcher.call(filing)
    InAppNotification.find_by!(filing:)
  end

  it "hints only when due publication changes an account inbox, preserving digest timing" do
    notification = match
    expect(notification.published_at).to be_nil
    expect(InAppInboxRealtime).not_to have_received(:after_commit)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(InAppInboxRealtime).to have_received(:after_commit).with([ user.id ]).once
    expect(notification.reload.published_at).to eq(Time.current)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "hints for real read changes and never for idempotent or unauthorized reads" do
    notification = match
    travel 1.hour
    InAppNotificationPublisher.call
    InAppNotificationReads.mark(user:, id: notification.id)
    InAppNotificationReads.mark(user:, id: notification.id)
    expect(InAppNotificationReads.mark_all(user:).fetch(:updated_count)).to eq(0)
    expect(InAppInboxRealtime).to have_received(:after_commit).with([ user.id ]).twice
    other = create(:user, email_address: "other@example.com")
    expect { InAppNotificationReads.mark(user: other, id: notification.id) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(InAppInboxRealtime).not_to have_received(:after_commit).with([ other.id ])
  end

  it "hints once for a changed read-all batch and excludes invalid sources" do
    first = match
    second = match
    travel 1.hour
    second.filing.update!(parse_status: "failed")
    expect(InAppNotificationPublisher.call).to eq(1)
    result = InAppNotificationReads.mark_all(user:)
    expect(result.fetch(:updated_count)).to eq(1)
    expect(InAppInboxRealtime).to have_received(:after_commit).with([ user.id ]).twice
    expect(first.reload.read_at).to be_present
    expect(second.reload.published_at).to be_nil
    expect(second.read_at).to be_nil
  end
end
