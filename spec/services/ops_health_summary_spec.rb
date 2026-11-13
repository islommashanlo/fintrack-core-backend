# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpsHealthSummary do
  let(:snapshot) do
    { ingestion: { pollers: { form4: { timestamp_in_future: false, seconds_since_last_successful_poll: 10 } },
      by_form: { "13F-HR" => {
        filings: { total: 10, failed: 0 }, parse_failures: { unresolved: 0, rate: 0 },
        live_ingestion_lag_seconds: { filings: 5, p95: 30, missing_filed_at: 0, negative_lag: 0, missing_ingested_at_total: 0 },
        live_backlog: { pending: 0, oldest_detected_age_seconds: nil, future_filed_at: 0 }
      } }, unclassified_parse_failures: { unresolved: 0 } },
      archives: { filesystem_checked: false, by_form: { "13F-HR" => { expected_documents: 20, missing_paths: 0, missing_reports: 0 } } },
      queues: { workers_checked: false, unknown_ready_queues_checked: false,
        ready: { "alerts" => { latency_status: "known", tail_age_seconds: 5 } },
        sets: { "scheduled" => { total_count: 2, due_count: 1, sampled_count: 2, truncated: false, counts_complete: true,
          malformed_payloads: 0, unattributed_payloads: 0 } } } }
  end

  def summary
    described_class.new(metrics: snapshot).to_h.deep_stringify_keys
  end

  def checks
    summary.fetch("checks").index_by { |check| check.fetch("id") }
  end

  it "keeps unchecked coverage unknown and does not mutate its input or perform I/O" do
    original = Marshal.dump(snapshot)
    expect(Filing).not_to receive(:connection)
    expect(Sidekiq).not_to receive(:redis)
    expect(FilingArchive).not_to receive(:default)
    result = summary
    expect(result).to include("status" => "unknown", "policy_version" => "ops-health-v2")
    expect(result.dig("counts", "attention")).to eq(0)
    expect(result.dig("counts", "unknown")).to eq(4)
    expect(Marshal.dump(snapshot)).to eq(original)
    expect(checks.fetch("set.scheduled")).to include("status" => "ok", "reason" => "counts_attributed")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "uses strict threshold boundaries and keeps attention above unknown in the rollup" do
    snapshot[:ingestion][:pollers][:form4][:seconds_since_last_successful_poll] = 300
    snapshot[:ingestion][:by_form]["13F-HR"][:live_ingestion_lag_seconds][:p95] = 600
    snapshot[:queues][:ready]["alerts"][:tail_age_seconds] = 600
    expect(checks.values.count { |check| check["status"] == "attention" }).to eq(0)
    snapshot[:ingestion][:pollers][:form4][:seconds_since_last_successful_poll] = 301
    expect(checks.fetch("poll.form4")).to include("status" => "attention", "threshold" => 300)
    expect(summary.fetch("status")).to eq("attention")
    expect(summary.dig("counts", "unknown")).to eq(4)
    snapshot[:ingestion][:by_form]["13F-HR"][:live_ingestion_lag_seconds][:p95] = 601
    snapshot[:queues][:ready]["alerts"][:tail_age_seconds] = 601
    expect(checks.fetch("form.13F-HR.latency").fetch("status")).to eq("attention")
    expect(checks.fetch("queue.alerts").fetch("status")).to eq("attention")
  end

  it "does not report zero-latency health without live samples or filings" do
    form = snapshot[:ingestion][:by_form]["13F-HR"]
    form[:filings][:total] = 0
    form[:live_ingestion_lag_seconds].merge!(filings: 0, p95: nil)
    snapshot[:ingestion][:pollers][:form4][:seconds_since_last_successful_poll] = nil
    snapshot[:archives][:by_form]["13F-HR"][:expected_documents] = 0
    %w[poll.form4 form.13F-HR.failures form.13F-HR.latency form.13F-HR.timing_coverage form.13F-HR.archive_references].each do |id|
      expect(checks.fetch(id).fetch("status")).to eq("unknown")
    end
  end

  it "flags attributed and unclassified failures, missing references and incomplete timing" do
    form = snapshot[:ingestion][:by_form]["13F-HR"]
    form[:parse_failures].merge!(unresolved: 1, rate: 0.1)
    form[:live_ingestion_lag_seconds][:negative_lag] = 1
    snapshot[:ingestion][:unclassified_parse_failures][:unresolved] = 1
    snapshot[:archives][:by_form]["13F-HR"][:missing_reports] = 1
    %w[form.13F-HR.failures form.13F-HR.timing_coverage form.13F-HR.archive_references unclassified_parse_failures].each do |id|
      expect(checks.fetch(id).fetch("status")).to eq("attention")
    end
    form[:parse_failures][:unresolved] = 0
    form[:filings][:failed] = 1
    expect(checks.fetch("form.13F-HR.failures").fetch("status")).to eq("attention")
  end

  it "watches detected backlog age while keeping missing and future timestamps explicit" do
    backlog = snapshot[:ingestion][:by_form]["13F-HR"][:live_backlog]
    backlog.merge!(pending: 1, oldest_detected_age_seconds: nil)
    expect(checks.fetch("form.13F-HR.backlog").fetch("status")).to eq("unknown")
    backlog[:oldest_detected_age_seconds] = 600
    expect(checks.fetch("form.13F-HR.backlog").fetch("status")).to eq("ok")
    backlog[:oldest_detected_age_seconds] = 601
    expect(checks.fetch("form.13F-HR.backlog").fetch("status")).to eq("attention")
    backlog[:future_filed_at] = 1
    expect(checks.fetch("form.13F-HR.backlog").fetch("reason")).to eq("future_acceptance_timestamp")
    snapshot[:ingestion][:pollers][:form4][:timestamp_in_future] = true
    expect(checks.fetch("poll.form4").fetch("reason")).to eq("future_poll_timestamp")
  end

  it "distinguishes empty queues, malformed payloads and unknown concurrent-read latency" do
    queue = snapshot[:queues][:ready]["alerts"]
    queue[:latency_status] = "empty"
    expect(checks.fetch("queue.alerts").fetch("status")).to eq("ok")
    queue[:latency_status] = "changed_during_read"
    expect(checks.fetch("queue.alerts").fetch("status")).to eq("unknown")
    %w[invalid_payload invalid_timestamp future_timestamp].each do |status|
      queue[:latency_status] = status
      expect(checks.fetch("queue.alerts")).to include("status" => "attention", "reason" => status)
    end
  end

  it "keeps truncated attribution unknown while surfacing known retry/dead records" do
    data = snapshot[:queues][:sets]["scheduled"]
    data.merge!(truncated: true, counts_complete: false)
    expect(checks.fetch("set.scheduled")).to include("status" => "unknown", "reason" => "incomplete_attribution")
    snapshot[:queues][:sets]["retry"] = data.dup
    snapshot[:queues][:sets]["dead"] = data.dup
    expect(checks.fetch("set.retry").fetch("status")).to eq("attention")
    expect(checks.fetch("set.dead").fetch("status")).to eq("attention")
    data[:malformed_payloads] = 1
    expect(checks.fetch("set.scheduled")).to include("status" => "attention", "reason" => "malformed_payloads")
  end

  it "rolls up a known notification failure while preserving unknown recipient coverage" do
    snapshot[:notifications] = { channels: {}, digest_batches: { total: 1, failed: 1, sending: 0, pending: 0,
      sending_missing_start_timestamp: 0, sending_future_start_timestamp: 0, sent_missing_completion_timestamp: 0, sent_future_completion_timestamp: 0 } }
    result = summary
    expect(result.fetch("status")).to eq("attention")
    expect(result.dig("counts", "attention")).to eq(1)
    expect(checks.fetch("notifications.digest_batches.failures").fetch("status")).to eq("attention")
    expect(checks.fetch("notifications.email").fetch("status")).to eq("unknown")
    expect(checks.fetch("workers").fetch("status")).to eq("unknown")
  end
end
