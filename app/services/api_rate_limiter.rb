# frozen_string_literal: true

class ApiRateLimiter
  SCRIPT = <<~LUA.freeze
    local count = redis.call('INCR', KEYS[1])
    if count == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[1]) end
    return {count, redis.call('PTTL', KEYS[1])}
  LUA

  class Limited < StandardError
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("Too many requests")
    end
  end

  class Unavailable < StandardError; end

  def self.check!(scope:, identifier:, limit:, window:)
    key = "api:rate_limit:#{scope}:#{Digest::SHA256.hexdigest(identifier.to_s)}"
    count, ttl = FilingsIntel.redis.call("EVAL", SCRIPT, 1, key, window.to_i * 1000)
    raise Limited, [ (ttl / 1000.0).ceil, 1 ].max if count > limit
  rescue RedisClient::Error
    raise Unavailable, "Request limiting is temporarily unavailable"
  end
end
