# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpsNotificationHealth do
  def timing(**attributes)
    { cohort_rows: 1, samples: 1, negative_lag: 0, p95: 120, **attributes }
  end

  def row
    { rows: { total: 1, failed: 0, completed: 1, pending: 0, missing_completion_timestamp_total: 0, future_completion_timestamp_total: 0 },
      completion_lag_seconds: timing, instant_sec_lag_seconds: timing(missing_filed_at: 0),
      oldest_pending_age_seconds: nil, publication_delay_seconds: timing,
      raw_due_pending: 0, eligible_due_pending: 0, future_pending: 0, oldest_eligible_due_age_seconds: nil }
  end

  let(:snapshot) do
    { channels: {
      email: { receipt_observed: false, failure_timestamp_recorded: false, completion_event: "recorded_mailer_return",
        failure_status_recorded: true, pending_eligibility_checked: false, by_frequency: { instant: row, daily_digest: row } },
      in_app: { receipt_observed: false, failure_timestamp_recorded: false, completion_event: "row_published",
        failure_status_recorded: false, pending_eligibility_checked: true, by_frequency: { instant: row, daily_digest: row } },
      push: { supported: false, receipt_observed: false } },
      digest_batches: { total: 1, failed: 0, sending: 0, pending: 0, oldest_pending_age_seconds: nil, oldest_sending_age_seconds: nil,
        sending_missing_start_timestamp: 0, sending_future_start_timestamp: 0, sent_missing_completion_timestamp: 0, sent_future_completion_timestamp: 0 } }
  end

  def checks
    described_class.new(notifications: snapshot).checks.map(&:deep_stringify_keys).index_by { |item| item.fetch("id") }
  end

  it "keeps receipt, email eligibility, in-app failures and push coverage unknown without I/O" do
    original = Marshal.dump(snapshot)
    expect(ApplicationRecord).not_to receive(:connection)
    expect(Sidekiq).not_to receive(:redis)
    %w[notifications.email.receipt notifications.in_app.receipt notifications.email.instant.backlog
      notifications.in_app.instant.failures notifications.push notifications.digest_batches.pending_eligibility].each do |id|
      expect(checks.fetch(id).fetch("status")).to eq("unknown")
    end
    expect(Marshal.dump(snapshot)).to eq(original)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "applies strict 120-second instant thresholds without thresholding daily capture-to-completion waits" do
    email = snapshot[:channels][:email][:by_frequency]
    expect(checks.fetch("notifications.email.instant.completion_lag").fetch("status")).to eq("ok")
    email[:instant][:completion_lag_seconds][:p95] = 121
    email[:instant][:instant_sec_lag_seconds][:p95] = 121
    email[:daily_digest][:completion_lag_seconds][:p95] = 86_400
    expect(checks.fetch("notifications.email.instant.completion_lag")).to include("status" => "attention", "threshold" => 120)
    expect(checks.fetch("notifications.email.instant.sec_lag").fetch("status")).to eq("attention")
    expect(checks).not_to have_key("notifications.email.daily_digest.completion_lag")
  end

  it "does not infer latency or acceptance coverage without samples or required stamps" do
    email = snapshot[:channels][:email][:by_frequency][:instant]
    email[:completion_lag_seconds].merge!(samples: 0, p95: nil)
    email[:instant_sec_lag_seconds].merge!(samples: 0, p95: nil, missing_filed_at: 1)
    expect(checks.fetch("notifications.email.instant.completion_lag").fetch("status")).to eq("unknown")
    expect(checks.fetch("notifications.email.instant.sec_lag").fetch("status")).to eq("unknown")
    expect(checks.fetch("notifications.email.instant.sec_timing_coverage").fetch("status")).to eq("unknown")
  end

  it "flags known email failures and all clock anomalies without inferring in-app failure tracking" do
    email = snapshot[:channels][:email][:by_frequency][:instant]
    email[:rows][:failed] = 1
    email[:rows][:missing_completion_timestamp_total] = 1
    expect(checks.fetch("notifications.email.instant.failures").fetch("status")).to eq("attention")
    expect(checks.fetch("notifications.email.instant.timestamps").fetch("status")).to eq("attention")
    app = snapshot[:channels][:in_app][:by_frequency][:daily_digest]
    app[:publication_delay_seconds][:negative_lag] = 1
    expect(checks.fetch("notifications.in_app.daily_digest.timestamps").fetch("status")).to eq("attention")
    expect(checks.fetch("notifications.in_app.daily_digest.failures").fetch("status")).to eq("unknown")
  end

  it "thresholds eligible in-app due age without treating future or suppressed rows as backlog" do
    app = snapshot[:channels][:in_app][:by_frequency][:daily_digest]
    app.merge!(raw_due_pending: 100, future_pending: 100)
    expect(checks.fetch("notifications.in_app.daily_digest.backlog").fetch("status")).to eq("ok")
    app.merge!(eligible_due_pending: 1, oldest_eligible_due_age_seconds: 120)
    expect(checks.fetch("notifications.in_app.daily_digest.backlog").fetch("status")).to eq("ok")
    app[:oldest_eligible_due_age_seconds] = 121
    expect(checks.fetch("notifications.in_app.daily_digest.backlog").fetch("status")).to eq("attention")
    app[:oldest_eligible_due_age_seconds] = nil
    expect(checks.fetch("notifications.in_app.daily_digest.backlog").fetch("status")).to eq("unknown")
  end

  it "reports digest failures and old sending states for review without making a retry decision" do
    batch = snapshot[:digest_batches]
    batch.merge!(failed: 1, sending: 1, oldest_sending_age_seconds: 600)
    expect(checks.fetch("notifications.digest_batches.failures").fetch("status")).to eq("attention")
    expect(checks.fetch("notifications.digest_batches.sending_age").fetch("status")).to eq("ok")
    batch[:oldest_sending_age_seconds] = 601
    expect(checks.fetch("notifications.digest_batches.sending_age")).to include("status" => "attention", "threshold" => 600)
    batch.merge!(oldest_sending_age_seconds: nil, sending_missing_start_timestamp: 1)
    expect(checks.fetch("notifications.digest_batches.sending_age").fetch("status")).to eq("unknown")
    expect(checks.fetch("notifications.digest_batches.timestamps").fetch("status")).to eq("attention")
  end

  it "preserves unknown status for empty outcomes and missing channel sections" do
    email = snapshot[:channels][:email][:by_frequency][:instant]
    email[:rows].merge!(total: 0, completed: 0)
    expect(checks.fetch("notifications.email.instant.failures").fetch("status")).to eq("unknown")
    expect(checks.fetch("notifications.email.instant.timestamps").fetch("status")).to eq("unknown")
    snapshot[:channels].delete(:in_app)
    expect(checks.fetch("notifications.in_app")).to include("status" => "unknown", "reason" => "channel_not_observed")
    snapshot.delete(:digest_batches)
    expect(checks.fetch("notifications.digest_batches").fetch("status")).to eq("unknown")
  end
end
