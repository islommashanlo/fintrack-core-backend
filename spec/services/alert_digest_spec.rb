# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Filing alert digests" do
  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }
  let(:user) { create(:user) }
  let(:rule) { enable_rule(create(:follow, user:).alert_rule) }

  def pending(at: 1.hour.ago, **attributes)
    create(:alert_delivery, alert_rule: rule, frequency: "daily_digest", created_at: at, **attributes)
  end

  it "claims one stable batch at 07:00 local time and sends one factual email" do
    consent_email(user)
    first = pending
    second = pending
    batch = AlertDigestPlanner.call(user:)
    expect(batch).to have_attributes(local_date: Date.new(2026, 11, 10), time_zone: "America/New_York")
    expect(batch.alert_deliveries.pluck(:id)).to contain_exactly(first.id, second.id)
    later = pending(at: Time.current)
    expect(AlertDigestPlanner.call(user:).id).to eq(batch.id)
    expect(batch.alert_deliveries.pluck(:id)).not_to include(later.id)
    expect { SendAlertDigestJob.perform_now(batch.id) }.to change { ActionMailer::Base.deliveries.length }.by(1)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Your SEC filing digest for 2026-11-10")
    expect(mail.body.encoded).to include(first.filing.accession_no, second.filing.accession_no, "Not investment advice")
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    expect(mail["List-Unsubscribe"].value).to start_with("<https://")
    expect(first.reload.status).to eq("sent")
    expect(later.reload.status).to eq("pending")
    expect { SendAlertDigestJob.perform_now(batch.id) }.not_to change { ActionMailer::Base.deliveries.length }
  end

  it "does not claim before local 07:00 and handles both US daylight-saving transitions" do
    consent_email(user)
    [ [ Time.utc(2026, 3, 8, 10, 59), Time.utc(2026, 3, 8, 11) ],
      [ Time.utc(2026, 11, 1, 11, 59), Time.utc(2026, 11, 1, 12) ] ].each do |before, due|
      travel_to(before)
      pending(at: before - 1.hour)
      expect(AlertDigestPlanner.call(user:)).to be_nil
      travel_to(due)
      expect(AlertDigestPlanner.call(user:)).to be_present
    end
  end

  it "keeps batch membership unchanged on retries and can retry a known transport failure" do
    consent_email(user)
    event = pending
    batch = AlertDigestPlanner.call(user:)
    allow(FilingDigestMailer).to receive(:daily).and_raise(StandardError, "transport unavailable")
    expect { SendAlertDigestJob.perform_now(batch.id) }.to raise_error(StandardError, "transport unavailable")
    expect(batch.reload.status).to eq("failed")
    pending(at: 2.hours.ago)
    expect(AlertDigestPlanner.call(user:).alert_deliveries.pluck(:id)).to eq([ event.id ])
    allow(FilingDigestMailer).to receive(:daily).and_call_original
    SendAlertDigestJob.perform_now(batch.id)
    expect(batch.reload.status).to eq("sent")
  end

  %i[unsubscribe pause archive removal downgrade time_zone].each do |change|
    it "cancels a queued batch after #{change}" do
      consent_email(user)
      event = pending
      if change == :downgrade
        allow(PlanCatalog).to receive(:limit_for).and_call_original
        allow(PlanCatalog).to receive(:limit_for).with(anything, :alert_rules).and_return(nil)
        3.times { |i| create(:follow, user:, target_key: "EXTRA#{i}") }
      end
      batch = AlertDigestPlanner.call(user:)
      case change
      when :unsubscribe then EmailUnsubscribe.disable(EmailUnsubscribe.token(user))
      when :pause then rule.update!(active: false)
      when :archive then AlertRuleControl.archive(user:, id: rule.id)
      when :removal then WatchlistMembership.remove(user:, id: rule.follow_id)
      when :downgrade then allow(PlanCatalog).to receive(:limit_for).with(anything, :alert_rules).and_return(3)
      when :time_zone then NotificationPreferences.update(user:, attributes: { time_zone: "America/Los_Angeles" })
      end
      expect { SendAlertDigestJob.perform_now(batch.id) }.not_to change { ActionMailer::Base.deliveries.length }
      expect(batch.reload.status).to eq("canceled")
      expect(event.reload.status).to eq("pending")
    end
  end

  it "does not resend an uncertain batch after provider acceptance and a database failure" do
    consent_email(user)
    pending
    batch = AlertDigestPlanner.call(user:)
    allow_any_instance_of(AlertDigestBatch).to receive(:update!).and_wrap_original do |original, **attributes|
      raise ActiveRecord::StatementInvalid, "commit failed" if attributes[:status] == "sent"
      original.call(**attributes)
    end
    expect { SendAlertDigestJob.perform_now(batch.id) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(batch.reload.status).to eq("sending")
    expect { SendAlertDigestJob.perform_now(batch.id) }.not_to change { ActionMailer::Base.deliveries.length }
  end

  it "does not email events from before consent or from a prior rule activation" do
    consent_email(user)
    event = pending
    rule.setting.update!(enabled_at: Time.current - 30.minutes)
    expect(AlertDigestPlanner.call(user:)).to be_nil
    rule.setting.update!(enabled_at: 1.year.ago)
    user.notification_preference.update!(email_enabled: false)
    user.notification_preference.update!(email_enabled: true)
    expect(AlertDigestPlanner.call(user:)).to be_nil
    expect(event.reload.status).to eq("pending")
  end

  it "schedules only due local zones while SEC polling is disabled" do
    consent_email(user, zone: "America/Los_Angeles")
    pending
    ScheduleAlertDigestsJob.perform_now
    expect(SendAlertDigestJob).not_to have_been_enqueued
    travel_to(Time.utc(2026, 11, 10, 15))
    ScheduleAlertDigestsJob.perform_now
    expect(SendAlertDigestJob).to have_been_enqueued.once
    expect(CronSchedule.jobs(polling: false).keys).to eq([ "alert_digests", "in_app_notifications" ])
  end

  it "keeps instant sends disabled for Free users even if a legacy rule is active" do
    consent_email(user)
    rule.setting.update!(frequency: "instant")
    event = create(:alert_delivery, alert_rule: rule, frequency: "instant")
    expect { SendAlertJob.perform_now(event.id) }.not_to change { ActionMailer::Base.deliveries.length }
    expect(event.reload.status).to eq("pending")
  end
end
