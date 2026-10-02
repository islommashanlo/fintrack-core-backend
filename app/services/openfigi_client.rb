# frozen_string_literal: true

# Small OpenFIGI adapter. It is deliberately separate from SecClient because
# OpenFIGI is an enrichment source, not SEC traffic. The client batches within
# the documented request limit and leaves persistence to a later ingest service.
class OpenfigiClient
  class Error < StandardError; end
  class TransientError < Error; end
  class RequestError < Error; end

  ENDPOINT = "https://api.openfigi.com"
  MAPPING_PATH = "/v3/mapping"
  AUTHENTICATED_BATCH_SIZE = 100
  UNAUTHENTICATED_BATCH_SIZE = 10
  AUTHENTICATED_INTERVAL = 0.25
  UNAUTHENTICATED_INTERVAL = 2.4

  def initialize(api_key: ENV["OPENFIGI_API_KEY"], connection: nil, sleeper: Kernel.method(:sleep), clock: Time)
    @api_key = api_key.presence
    @connection = connection || Faraday.new(url: ENDPOINT)
    @sleeper = sleeper
    @clock = clock
    @batch_size = @api_key ? AUTHENTICATED_BATCH_SIZE : UNAUTHENTICATED_BATCH_SIZE
    @interval = @api_key ? AUTHENTICATED_INTERVAL : UNAUTHENTICATED_INTERVAL
    @last_request_at = nil
  end

  def map(cusips)
    normalized = cusips.filter_map { |cusip| normalize(cusip) }.uniq
    normalized.each_slice(@batch_size).flat_map { |batch| request(batch) }
  end

  attr_reader :batch_size

  private

  def request(cusips)
    wait_for_rate_limit
    response = @connection.post(MAPPING_PATH) do |request|
      request.headers["Content-Type"] = "application/json"
      request.headers["X-OPENFIGI-APIKEY"] = @api_key if @api_key
      request.body = cusips.map { |cusip| { idType: "ID_CUSIP", idValue: cusip } }.to_json
    end
    @last_request_at = @clock.now

    case response.status
    when 200
      OpenfigiResponseParser.parse(cusips:, body: response.body)
    when 429, 500, 503
      raise TransientError, "OpenFIGI request failed with HTTP #{response.status}"
    else
      raise RequestError, "OpenFIGI request failed with HTTP #{response.status}"
    end
  end

  def wait_for_rate_limit
    return unless @last_request_at

    elapsed = @clock.now - @last_request_at
    @sleeper.call(@interval - elapsed) if elapsed < @interval
  end

  def normalize(cusip)
    value = cusip.to_s.strip.upcase
    value if value.match?(/\A[0-9A-Z]{9}\z/)
  end
end
