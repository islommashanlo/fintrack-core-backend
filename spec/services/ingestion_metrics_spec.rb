# frozen_string_literal: true

require "rails_helper"

RSpec.describe IngestionMetrics do
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }

  def metrics
    described_class.new.to_h.deep_stringify_keys
  end

  def live(form: "13F-HR", lag: 120, **attributes)
    create(:filing, form_type: form, source: "efts", filed_at: 1.hour.ago,
      ingested_at: 1.hour.ago + lag.seconds, parsed_at: 1.hour.ago + lag.seconds, **attributes)
  end

  it "returns every supported form with explicit empty coverage and independent poll timestamps" do
    FilingsIntel.redis.call("SET", EdgarPoller::LAST_SUCCESS_KEY, 42.seconds.ago.iso8601)
    FilingsIntel.redis.call("SET", Edgar13fPoller::LAST_SUCCESS_KEY, 90.seconds.ago.iso8601)
    result = metrics
    expect(result.fetch("by_form").keys).to match_array(Filing::SEC_INGEST_TYPES)
    expect(result.dig("by_form", "13F-HR", "parse_failures", "rate")).to be_nil
    expect(result.dig("by_form", "13F-HR", "live_ingestion_lag_seconds")).to include("filings" => 0, "median" => nil, "p95" => nil)
    expect(result.dig("pollers", "form4", "seconds_since_last_successful_poll")).to eq(42)
    expect(result.dig("pollers", "form13f", "seconds_since_last_successful_poll")).to eq(90)
    expect(result.fetch("window_end")).to eq(Time.current.iso8601)
  end

  it "separates acceptance-to-first-ingest percentiles by exact form and excludes backfill and reparsing times" do
    [ 60, 120, 600 ].each { |lag| live(lag:) }
    live(form: "4", lag: 10)
    live(form: "13F-HR/A", lag: 900)
    live(form: "13F-NT", lag: 30)
    live(source: "daily_index", lag: 50_000)
    live(ingested_at: 2.days.ago, parsed_at: Time.current)
    live(parsed_at: Time.current, lag: 60)
    lag = metrics.dig("by_form", "13F-HR", "live_ingestion_lag_seconds")
    expect(lag).to include("filings" => 4, "cohort_filings" => 4, "median" => 90, "p95" => 528)
    expect(metrics.dig("by_form", "4", "live_ingestion_lag_seconds", "p95")).to eq(10)
    expect(metrics.dig("by_form", "13F-HR/A", "live_ingestion_lag_seconds", "p95")).to eq(900)
  end

  it "reports missing and invalid timing coverage without producing negative latencies" do
    live(filed_at: nil)
    live(filed_at: Time.current)
    live(ingested_at: nil)
    live(ingested_at: 1.second.from_now)
    lag = metrics.dig("by_form", "13F-HR", "live_ingestion_lag_seconds")
    expect(lag).to include("filings" => 0, "cohort_filings" => 2, "median" => nil, "p95" => nil,
      "missing_filed_at" => 1, "negative_lag" => 1, "missing_ingested_at_total" => 1)
  end

  it "keeps skipped pre-XML reports separate from parsed content and live latency" do
    filing = live
    create(:institutional_report, filing:, status: "skipped", submission_type: "13F-HR")
    row = metrics.dig("by_form", "13F-HR")
    expect(row.fetch("filings")).to include("total" => 1, "parsed" => 0, "skipped" => 1, "parsed_last_24h" => 0, "skipped_last_24h" => 1)
    expect(row.dig("live_ingestion_lag_seconds", "filings")).to eq(0)
  end

  it "attributes unique unresolved failures by accession while exposing unclassified failures separately" do
    bad = live(parse_status: "failed")
    live
    other = live(form: "4", parse_status: "failed")
    resolved = live(form: "13F-HR/A")
    ParseFailure.record!(bad.accession_no, "bad XML")
    ParseFailure.record!(bad.accession_no, "still bad XML")
    ParseFailure.record!(other.accession_no, "bad XML")
    ParseFailure.record!(resolved.accession_no, "old problem")
    ParseFailure.resolve!(resolved.accession_no)
    ParseFailure.record!("0000000001-26-000001", "unknown filing")
    unknown = create(:filing, form_type: "UNKNOWN")
    ParseFailure.record!(unknown.accession_no, "unsupported form")
    result = metrics
    expect(result.dig("by_form", "13F-HR", "parse_failures")).to eq("unresolved" => 1, "failed_last_24h" => 1, "rate" => 0.5)
    expect(result.dig("by_form", "4", "parse_failures", "rate")).to eq(1.0)
    expect(result.dig("by_form", "13F-HR/A", "parse_failures", "unresolved")).to eq(0)
    expect(result.fetch("unclassified_parse_failures")).to eq("unresolved" => 2, "failed_last_24h" => 2)
  end

  it "measures live pending age from detection even without acceptance timestamps and excludes backfill" do
    live(parse_status: "pending", filed_at: nil, created_at: 10.minutes.ago)
    live(parse_status: "pending", created_at: 5.minutes.ago)
    live(parse_status: "pending", filed_at: 1.hour.from_now, created_at: 1.minute.ago)
    live(parse_status: "pending", source: "daily_index", created_at: 2.days.ago)
    live(form: "4", parse_status: "pending", created_at: 20.minutes.ago)
    row = metrics.dig("by_form", "13F-HR")
    expect(row.dig("filings", "pending")).to eq(4)
    expect(row.fetch("live_backlog")).to eq("pending" => 3, "missing_filed_at" => 1, "future_filed_at" => 1,
      "oldest_detected_age_seconds" => 600, "oldest_acceptance_age_seconds" => 3600)
  end

  it "uses closed 24-hour bounds, excludes future records and separates stale unresolved failures" do
    live(ingested_at: 24.hours.ago, filed_at: 24.hours.ago - 60, parsed_at: 24.hours.ago)
    live(ingested_at: 24.hours.ago - 1, parsed_at: 24.hours.ago - 1)
    live(ingested_at: 1.second.from_now, parsed_at: 1.second.from_now)
    live(created_at: 1.second.from_now)
    stale = live(parse_status: "failed")
    ParseFailure.record!(stale.accession_no, "old problem")
    ParseFailure.find_by!(accession_no: stale.accession_no).update!(last_failed_at: 24.hours.ago - 1)
    row = metrics.dig("by_form", "13F-HR")
    expect(row.dig("live_ingestion_lag_seconds", "filings")).to eq(1)
    expect(row.fetch("filings")).to include("total" => 4, "parsed_last_24h" => 1)
    expect(row.fetch("parse_failures")).to include("unresolved" => 1, "failed_last_24h" => 0)
  end

  it "returns unknown poll age before first success and flags future poll timestamps" do
    expect(metrics.dig("pollers", "form13f")).to include("last_successful_poll_at" => nil, "seconds_since_last_successful_poll" => nil)
    FilingsIntel.redis.call("SET", Edgar13fPoller::LAST_SUCCESS_KEY, 1.minute.from_now.iso8601)
    expect(metrics.dig("pollers", "form13f")).to include("seconds_since_last_successful_poll" => nil, "timestamp_in_future" => true)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
