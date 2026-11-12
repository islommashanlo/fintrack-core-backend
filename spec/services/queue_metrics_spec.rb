# frozen_string_literal: true

require "rails_helper"

RSpec.describe QueueMetrics do
  around { |example| travel_to(Time.utc(2026, 11, 12, 12)) { example.run } }

  def redis(*arguments)
    Sidekiq.redis { |connection| connection.call(*arguments) }
  end

  def metrics
    described_class.new.to_h.deep_stringify_keys
  end

  def enqueue(queue, **attributes)
    redis("LPUSH", "queue:#{queue}", JSON.generate({ "queue" => queue, "enqueued_at" => 1.minute.ago.to_i * 1000,
      "args" => [ "private contents" ], **attributes.transform_keys(&:to_s) }))
  end

  it "includes every configured ready queue without claiming worker or unknown-queue coverage" do
    result = metrics
    expect(result.fetch("ready").keys).to match_array(%w[sec_live_form4 sec_live_13f sec_backfill_13f alerts default])
    expect(result.fetch("ready").values).to all(include("size" => 0, "tail_age_seconds" => nil, "latency_status" => "empty"))
    expect(result).to include("workers_checked" => false, "unknown_ready_queues_checked" => false)
    expect(result.dig("sets", "retry")).to include("total_count" => 0, "due_count" => 0, "counts_complete" => true)
  end

  it "measures the tail age for each ready queue with millisecond and legacy floating timestamps" do
    enqueue("sec_live_form4", enqueued_at: 2.minutes.ago.to_i * 1000)
    enqueue("sec_live_form4", enqueued_at: 10.seconds.ago.to_i * 1000)
    enqueue("alerts", enqueued_at: 30.seconds.ago.to_f)
    enqueue("default", enqueued_at: nil, created_at: 45.seconds.ago.to_f)
    result = metrics
    expect(result.dig("ready", "sec_live_form4")).to include("size" => 2, "tail_age_seconds" => 120, "latency_status" => "known")
    expect(result.dig("ready", "alerts", "tail_age_seconds")).to eq(30)
    expect(result.dig("ready", "default")).to include("tail_age_seconds" => 45, "timestamp_source" => "created_at")
  end

  it "keeps malformed, missing and future timestamp coverage explicit" do
    redis("LPUSH", "queue:sec_live_form4", "invalid json")
    enqueue("sec_live_13f", enqueued_at: nil)
    enqueue("sec_backfill_13f", enqueued_at: 1.minute.from_now.to_i * 1000)
    enqueue("alerts", enqueued_at: "wrong type")
    rows = metrics.fetch("ready")
    expect(rows.fetch("sec_live_form4").fetch("latency_status")).to eq("invalid_payload")
    expect(rows.fetch("sec_live_13f").fetch("latency_status")).to eq("missing_timestamp")
    expect(rows.fetch("sec_backfill_13f").fetch("latency_status")).to eq("future_timestamp")
    expect(rows.fetch("alerts").fetch("latency_status")).to eq("invalid_timestamp")
    expect(rows.values.pluck("tail_age_seconds")).to all(be_nil)
  end

  it "marks inconsistent size and tail observations as a concurrent-read change" do
    connection = double("read-only Redis metadata connection")
    replies = [ 1, nil, 0, nil, 0, nil, 0, JSON.generate("enqueued_at" => 1.minute.ago.to_f), 0, nil,
      0, [], 0, 0, [], 0, 0, [] ]
    allow(connection).to receive(:pipelined).and_return(replies)
    allow(Sidekiq).to receive(:redis).and_yield(connection)
    result = metrics
    %w[sec_live_form4 alerts].each do |queue|
      expect(result.dig("ready", queue)).to include("latency_status" => "changed_during_read", "tail_age_seconds" => nil)
    end
  end

  it "attributes complete small sets to queues without exposing job contents" do
    redis("ZADD", "retry", 1.minute.ago.to_f, JSON.generate("queue" => "sec_live_13f", "args" => [ "private" ]))
    redis("ZADD", "retry", 1.minute.from_now.to_f, JSON.generate("queue" => "vendor_queue"))
    redis("ZADD", "schedule", 1.minute.from_now.to_f, JSON.generate("queue" => "alerts"))
    redis("ZADD", "dead", 1.minute.ago.to_f, JSON.generate("queue" => "default"))
    result = metrics
    expect(result.dig("sets", "retry")).to include("total_count" => 2, "due_count" => 1, "counts_complete" => true, "truncated" => false)
    expect(result.dig("sets", "retry", "by_queue", "sec_live_13f")).to eq("observed" => 1, "total" => 1)
    expect(result.dig("sets", "retry", "by_queue", "other", "total")).to eq(1)
    expect(result.dig("sets", "scheduled", "due_count")).to eq(0)
    expect(result.dig("sets", "dead", "due_count")).to be_nil
    expect(JSON.generate(result)).not_to include("private", "args", "vendor_queue")
  end

  it "caps sorted-set samples and keeps unobserved queue totals unknown" do
    (described_class::SAMPLE_LIMIT + 5).times do |index|
      redis("ZADD", "retry", Time.current.to_f + index, JSON.generate("queue" => "alerts", "jid" => index))
    end
    row = metrics.dig("sets", "retry")
    expect(row).to include("total_count" => 105, "sampled_count" => 100, "sample_limit" => 100, "truncated" => true, "counts_complete" => false)
    expect(row.dig("by_queue", "alerts")).to eq("observed" => 100, "total" => nil)
    expect(row.dig("by_queue", "sec_live_form4")).to eq("observed" => 0, "total" => nil)
  end

  it "does not infer exact queue counts from malformed or unattributed jobs" do
    redis("ZADD", "dead", 1, "not json")
    redis("ZADD", "dead", 2, "[]")
    redis("ZADD", "dead", 3, JSON.generate("class" => "ExampleJob"))
    row = metrics.dig("sets", "dead")
    expect(row).to include("total_count" => 3, "sampled_count" => 3, "malformed_payloads" => 2, "unattributed_payloads" => 1,
      "truncated" => false, "counts_complete" => false)
    expect(row.fetch("by_queue").values.pluck("total")).to all(be_nil)
  end

  it "leaves queues, sorted sets, process registrations and schedules untouched" do
    enqueue("alerts")
    redis("ZADD", "retry", 1, JSON.generate("queue" => "alerts"))
    redis("SADD", "processes", "stale-process")
    before = %w[queue:alerts retry processes].to_h { |key| [ key, redis("DUMP", key) ] }
    expect(Sidekiq::ProcessSet).not_to receive(:new)
    expect(Sidekiq::Cron::Job).not_to receive(:load_from_hash!)
    metrics
    expect(before).to eq(before.keys.to_h { |key| [ key, redis("DUMP", key) ] })
    expect(redis("EXISTS", "process_cleanup")).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end
end
