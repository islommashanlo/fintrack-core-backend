# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecRateLimiter do
  let(:sleeps) { [] }
  let(:recording_sleeper) { ->(seconds) { sleeps << seconds } }

  it "lets the first caller through without waiting" do
    limiter = described_class.new(sleeper: recording_sleeper)

    expect(limiter.acquire).to eq(0)
    expect(sleeps).to be_empty
  end

  it "spaces back-to-back callers one fifth of a second apart" do
    limiter = described_class.new(sleeper: recording_sleeper)

    waits = Array.new(6) { limiter.acquire }

    # The sleeper is a stub, so each caller is handed the next slot in the queue:
    # roughly 0s, 0.2s, 0.4s ... minus the few milliseconds the loop itself took.
    waits.each_with_index do |wait, i|
      expect(wait).to be_within(0.05).of(i * 0.2)
    end
    expect(sleeps).to eq(waits.drop(1))
  end

  it "shares one budget between separate limiter instances" do
    described_class.new(sleeper: recording_sleeper).acquire

    expect(described_class.new(sleeper: recording_sleeper).acquire).to be_within(0.05).of(0.2)
  end

  it "never lets more than the rate through in real time, across threads" do
    rate = 50
    finished_at = Queue.new

    threads = Array.new(4) do
      Thread.new do
        limiter = described_class.new(rate: rate, key: "sec:rate_limiter:spec")
        5.times do
          limiter.acquire
          finished_at << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
    threads.each(&:join)

    times = Array.new(finished_at.size) { finished_at.pop }.sort
    expect(times.size).to eq(20)
    # 20 requests at 50/s need at least 19 intervals of 20ms.
    expect(times.last - times.first).to be >= 0.36
  end
end
