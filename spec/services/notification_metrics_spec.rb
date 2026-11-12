# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationMetrics do
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }
  let(:email_rule) { create(:follow).alert_rule }

  def metrics
    described_class.new.to_h.deep_stringify_keys
  end

  def email(**attributes)
    create(:alert_delivery, alert_rule: email_rule, created_at: 10.minutes.ago, **attributes)
  end

  def in_app(frequency: "daily_digest", **attributes)
    @user_sequence = (@user_sequence || 0) + 1
    user = create(:user, email_address: "notification-metrics-#{@user_sequence}@example.com")
    follow = create(:follow, user:, skip_default_alert_rule: true)
    preference = NotificationPreferences.update(user: follow.user, attributes: { time_zone: "UTC" })
    rule = follow.alert_rules.create!(channel: "in_app", event_type: "new_filing", active: true)
    rule.setting.update!(frequency:, enabled_at: 1.day.ago)
    filing = create(:filing, filed_at: 30.minutes.ago, source: "efts", issuer_ticker: "ACME")
    InAppNotification.create!(alert_rule: rule, filing:, rule_revision: rule.setting.revision, frequency:,
      time_zone: preference.time_zone, available_at: 5.minutes.ago, created_at: 10.minutes.ago, **attributes)
  end

  it "returns explicit empty channel coverage without sending or enqueueing" do
    mails = ActionMailer::Base.deliveries.size
    expect do
      result = metrics
      expect(result.dig("channels", "email")).to include("completion_event" => "recorded_mailer_return", "receipt_observed" => false, "pending_eligibility_checked" => false)
      expect(result.dig("channels", "in_app")).to include("completion_event" => "row_published", "failure_status_recorded" => false)
      expect(result.dig("channels", "push")).to include("supported" => false)
      expect(result.dig("channels", "email", "by_frequency", "instant", "completion_lag_seconds")).to include("samples" => 0, "median" => nil, "p95" => nil)
      expect(result.dig("channels", "email", "by_frequency", "daily_digest", "instant_sec_lag_seconds")).to be_nil
    end.not_to have_enqueued_job
    expect(ActionMailer::Base.deliveries.size).to eq(mails)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "separates frequency/state counts and measures recorded completion without inferring failure times" do
    [ 60, 120, 600 ].each { |lag| email(status: "sent", created_at: 1.hour.ago, delivered_at: 1.hour.ago + lag.seconds) }
    email(status: "failed", error: "private transport details")
    email
    email(frequency: "daily_digest", status: "sent", delivered_at: Time.current)
    row = metrics.dig("channels", "email", "by_frequency", "instant")
    expect(row.fetch("rows")).to include("total" => 5, "pending" => 1, "failed" => 1, "completed" => 3, "completed_last_24h" => 3)
    expect(row.fetch("completion_lag_seconds")).to include("samples" => 3, "median" => 120, "p95" => 552)
    expect(row.fetch("oldest_pending_age_seconds")).to eq(600)
    expect(JSON.generate(metrics)).not_to include("private transport details", "error", "email_address")
  end

  it "reports missing, future and negative completion timestamps while preserving stored rows" do
    missing = email(status: "sent", delivered_at: nil)
    email(status: "sent", delivered_at: 1.minute.from_now)
    email(status: "sent", created_at: 1.minute.ago, delivered_at: 2.minutes.ago)
    row = metrics.dig("channels", "email", "by_frequency", "instant")
    expect(row.fetch("rows")).to include("completed" => 3, "missing_completion_timestamp_total" => 1, "future_completion_timestamp_total" => 1)
    expect(row.fetch("completion_lag_seconds")).to include("cohort_rows" => 1, "samples" => 0, "negative_lag" => 1, "p95" => nil)
    expect(missing.reload.delivered_at).to be_nil
  end

  it "limits SEC acceptance lag to live instant direct filing events and keeps missing acceptance unknown" do
    filing = create(:filing, source: "efts", filed_at: 1.hour.ago)
    email(filing:, status: "sent", delivered_at: 1.hour.ago + 120, created_at: 1.hour.ago)
    email(filing: create(:filing, source: "daily_index"), status: "sent", delivered_at: Time.current)
    email(frequency: "daily_digest", filing: create(:filing, source: "efts", filed_at: 1.hour.ago), status: "sent", delivered_at: Time.current)
    email(filing: create(:filing, source: "efts", filed_at: nil), status: "sent", delivered_at: Time.current)
    row = metrics.dig("channels", "email", "by_frequency", "instant", "instant_sec_lag_seconds")
    expect(row).to include("cohort_rows" => 2, "samples" => 1, "missing_filed_at" => 1, "median" => 120, "p95" => 120)
  end

  it "separates in-app due time from creation lag and policy-suppressed pending rows" do
    eligible = in_app
    blocked = in_app
    blocked.alert_rule.update!(active: false)
    in_app(available_at: 1.hour.from_now)
    in_app(published_at: Time.current)
    row = metrics.dig("channels", "in_app", "by_frequency", "daily_digest")
    expect(row.fetch("rows")).to include("total" => 4, "pending" => 3, "completed" => 1, "failed" => 0)
    expect(row).to include("raw_due_pending" => 2, "eligible_due_pending" => 1, "future_pending" => 1, "oldest_eligible_due_age_seconds" => 300)
    expect(row.dig("completion_lag_seconds", "median")).to eq(600)
    expect(row.dig("publication_delay_seconds", "median")).to eq(300)
    expect(eligible.reload.published_at).to be_nil
  end

  it "keeps early publication anomalies separate from valid completion lag" do
    in_app(published_at: Time.current, available_at: 1.hour.from_now)
    row = metrics.dig("channels", "in_app", "by_frequency", "daily_digest")
    expect(row.dig("completion_lag_seconds", "samples")).to eq(1)
    expect(row.fetch("publication_delay_seconds")).to include("negative_lag" => 1, "samples" => 0, "median" => nil)
  end

  it "uses closed 24-hour completion bounds and excludes future-created rows" do
    email(status: "sent", created_at: 2.days.ago, delivered_at: 24.hours.ago)
    email(status: "sent", created_at: 2.days.ago, delivered_at: 24.hours.ago - 1)
    email(status: "sent", created_at: 1.minute.ago, delivered_at: Time.current)
    email(status: "sent", created_at: 1.minute.from_now, delivered_at: 2.minutes.from_now)
    row = metrics.dig("channels", "email", "by_frequency", "instant")
    expect(row.fetch("rows")).to include("total" => 3, "completed_last_24h" => 2)
    expect(row.dig("completion_lag_seconds", "samples")).to eq(2)
  end

  it "counts digest messages separately from rows and keeps sending outcomes unresolved" do
    user = create(:user)
    %w[pending sending sent failed canceled].each_with_index do |status, index|
      AlertDigestBatch.create!(user:, local_date: Date.current - index, time_zone: "UTC", status:,
        created_at: 1.hour.ago, started_at: status == "sending" ? 30.minutes.ago : nil,
        delivered_at: status == "sent" ? Time.current : nil)
    end
    AlertDigestBatch.create!(user:, local_date: 10.days.ago.to_date, time_zone: "UTC", status: "sending", created_at: 1.hour.ago)
    result = metrics.fetch("digest_batches")
    expect(result).to include("total" => 6, "pending" => 1, "sending" => 2, "sent" => 1, "failed" => 1, "canceled" => 1,
      "sent_last_24h" => 1, "sending_missing_start_timestamp" => 1, "oldest_sending_age_seconds" => 1800)
    expect(metrics.dig("channels", "email", "by_frequency", "daily_digest", "rows", "total")).to eq(0)
  end
end
