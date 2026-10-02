# frozen_string_literal: true

# Global request budget for SEC hosts, shared by every process and thread through Redis.
#
# Each call reserves the next free slot and sleeps until it arrives. Slots are spaced
# 1/RATE seconds apart, so no rolling one-second window holds more than RATE requests,
# however many workers are running. Redis's clock is used so hosts with skewed clocks agree.
class SecRateLimiter
  RATE = 5 # requests per second, across everything
  KEY = "sec:rate_limiter:next_free"

  # KEYS[1] holds the time (microseconds) at which the next slot is free.
  # Returns how long the caller must wait for the slot it was just given.
  RESERVE_SLOT = <<~LUA
    local time = redis.call('TIME')
    local now = tonumber(time[1]) * 1000000 + tonumber(time[2])
    local interval = tonumber(ARGV[1])
    local next_free = tonumber(redis.call('GET', KEYS[1]) or '0')
    local slot = math.max(now, next_free)
    local ttl_ms = math.floor((slot - now) / 1000) + 60000
    redis.call('SET', KEYS[1], string.format('%.0f', slot + interval), 'PX', ttl_ms)
    return slot - now
  LUA

  def initialize(redis: FilingsIntel.redis, rate: RATE, key: KEY, sleeper: Kernel.method(:sleep))
    @redis = redis
    @interval_us = (1_000_000.0 / rate).ceil
    @key = key
    @sleeper = sleeper
  end

  # Blocks until this caller's slot arrives. Returns the seconds it waited.
  def acquire
    wait = @redis.call("EVAL", RESERVE_SLOT, 1, @key, @interval_us) / 1_000_000.0
    @sleeper.call(wait) if wait.positive?
    wait
  end
end
