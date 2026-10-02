# frozen_string_literal: true

# Shared Redis connection pool for application code (the SEC rate limiter, poller state).
# Sidekiq keeps its own connections; see config/initializers/sidekiq.rb.
module FilingsIntel
  def self.redis
    @redis ||= RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
                          .new_pool(size: Integer(ENV.fetch("REDIS_POOL_SIZE", 10)), timeout: 5)
  end
end
