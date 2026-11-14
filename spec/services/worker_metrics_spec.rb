# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkerMetrics do
  around { |example| travel_to(Time.utc(2026, 11, 13, 12)) { example.run } }

  def redis(*arguments)
    Sidekiq.redis { |connection| connection.call(*arguments) }
  end

  def register(key, beat: Time.current.to_f, quiet: "false", info: JSON.generate("queues" => [ "alerts", "alerts" ], "hostname" => "private-host"))
    redis("SADD", "processes", key)
    redis("HSET", key, "info", info, "beat", beat, "quiet", quiet)
  end

  def metrics
    described_class.new(queues: %w[alerts default]).to_h.deep_stringify_keys
  end

  it "observes an empty registry without inferring consumers or starting workers" do
    expect(metrics).to include("checked" => true, "registered_count" => 0, "sampled_count" => 0, "complete" => true)
    expect(metrics.dig("queues", "alerts")).to include("observed_active_consumers" => 0, "coverage_complete" => true)
  end

  it "counts recent nonquiet consumers once per process without exposing identities" do
    register("private-worker", beat: 60.seconds.ago.to_f)
    register("quiet-worker", quiet: "true")
    result = metrics
    expect(result.fetch("states")).to include("active" => 1, "quiet" => 1)
    expect(result.dig("queues", "alerts", "observed_active_consumers")).to eq(1)
    expect(result.to_json).not_to match(/private-worker|private-host|quiet-worker/)
    expect(redis("SMEMBERS", "processes")).to match_array(%w[private-worker quiet-worker])
    expect(redis("EXISTS", "process_cleanup")).to eq(0)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "retains stale, future, missing and malformed observations without cleanup" do
    register("stale", beat: 61.seconds.ago.to_f)
    register("future", beat: 1.second.from_now.to_f)
    register("invalid-json", info: "bad")
    register("invalid-type", info: "[]")
    register("invalid-time", beat: "NaN")
    register("invalid-quiet", quiet: "unknown")
    redis("SADD", "processes", "missing")
    expect(metrics.fetch("states")).to include("active" => 0, "stale" => 1, "future" => 1, "missing" => 1, "invalid" => 4)
    expect(redis("SCARD", "processes")).to eq(7)
    expect(metrics.dig("queues", "alerts", "coverage_complete")).to be(false)
  end

  it "bounds hash reads even if Redis returns an oversized scan batch" do
    connection = double("read-only process metadata")
    allow(Sidekiq).to receive(:redis).and_yield(connection)
    expect(connection).to receive(:call).with("SCARD", "processes").and_return(150)
    expect(connection).to receive(:call).with("SSCAN", "processes", "0", "COUNT", 100).and_return([ "0", 150.times.map(&:to_s) ])
    pipeline = double("pipeline")
    expect(connection).to receive(:pipelined).and_yield(pipeline).and_return(Array.new(100) { [ nil, nil, nil ] })
    expect(pipeline).to receive(:call).with("HMGET", anything, "info", "beat", "quiet").exactly(100).times
    expect(metrics).to include("complete" => false, "sampled_count" => 100, "registered_count" => 150)
  end

  it "keeps a nonterminal scan partial even when observed counts happen to agree" do
    connection = double("read-only process metadata")
    allow(Sidekiq).to receive(:redis).and_yield(connection)
    expect(connection).to receive(:call).with("SCARD", "processes").and_return(0)
    expect(connection).to receive(:call).with("SSCAN", "processes", "0", "COUNT", 100).and_return([ "12", [] ])
    expect(metrics.fetch("complete")).to be(false)
  end

  it "propagates infrastructure failures rather than fabricating healthy observations" do
    allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError)
    expect { metrics }.to raise_error(RedisClient::CannotConnectError)
  end
end
