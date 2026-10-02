# frozen_string_literal: true

# The only code allowed to make HTTP requests to the SEC (invariant 1).
#
# Every request waits for a slot from SecRateLimiter, carries a User-Agent with the
# contact address from SEC_USER_AGENT_EMAIL, and backs off on 429/503, honoring
# Retry-After. Errors are split into TransientError (worth retrying later) and
# everything else (deterministic; retrying will not help).
class SecClient
  class Error < StandardError
    attr_reader :url, :status

    def initialize(message, url:, status: nil)
      super(message)
      @url = url
      @status = status
    end
  end

  # Network failures, 5xx responses, and 429/503 that outlasted the backoff.
  class TransientError < Error; end
  class NotFound < Error; end
  # Any other 4xx.
  class RequestError < Error; end
  class ConfigurationError < StandardError; end

  ALLOWED_HOSTS = %w[www.sec.gov efts.sec.gov].freeze
  BACKOFF_STATUSES = [ 429, 503 ].freeze
  MAX_BACKOFF_RETRIES = 3
  MAX_RETRY_AFTER = 120 # seconds; a longer hint is treated as a failure, not slept through
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30

  def initialize(limiter: SecRateLimiter.new, sleeper: Kernel.method(:sleep), email: ENV["SEC_USER_AGENT_EMAIL"])
    raise ConfigurationError, "SEC_USER_AGENT_EMAIL must be set to a contact address" if email.blank?

    @limiter = limiter
    @sleeper = sleeper
    @user_agent = "FilingsIntel #{email}"
  end

  # Returns the response body for a 200. Raises one of the errors above otherwise.
  def get(url)
    ensure_sec_url!(url)
    retries = 0

    loop do
      @limiter.acquire
      response = perform(url)

      case response.status
      when 200
        return response.body
      when *BACKOFF_STATUSES
        retries += 1
        delay = retry_delay(response, retries)
        if retries > MAX_BACKOFF_RETRIES || delay > MAX_RETRY_AFTER
          raise TransientError.new("SEC asked us to back off (HTTP #{response.status})", url:, status: response.status)
        end
        @sleeper.call(delay)
      when 404
        raise NotFound.new("Not found", url:, status: 404)
      when 500..599
        raise TransientError.new("SEC server error (HTTP #{response.status})", url:, status: response.status)
      else
        raise RequestError.new("Unexpected response (HTTP #{response.status})", url:, status: response.status)
      end
    end
  end

  def get_json(url)
    JSON.parse(get(url))
  rescue JSON::ParserError => e
    raise RequestError.new("Response was not JSON: #{e.message.truncate(100)}", url:)
  end

  private

  def perform(url)
    connection.get(url)
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
    raise TransientError.new("#{e.class.name.demodulize}: #{e.message}", url:)
  end

  def connection
    @connection ||= Faraday.new(headers: { "User-Agent" => @user_agent }) do |f|
      f.options.open_timeout = OPEN_TIMEOUT
      f.options.timeout = READ_TIMEOUT
    end
  end

  def ensure_sec_url!(url)
    uri = URI.parse(url)
    return if uri.scheme == "https" && ALLOWED_HOSTS.include?(uri.host)

    raise ArgumentError, "SecClient only talks to #{ALLOWED_HOSTS.join(' and ')} over https: #{url}"
  end

  # Retry-After may be a number of seconds or an HTTP date. Without it, back off 1s, 2s, 4s.
  def retry_delay(response, retries)
    header = response.headers["Retry-After"].to_s.strip
    return 2**(retries - 1) if header.empty?
    return header.to_i if header.match?(/\A\d+\z/)

    [ Time.httpdate(header) - Time.now, 0 ].max.ceil
  rescue ArgumentError
    2**(retries - 1)
  end
end
