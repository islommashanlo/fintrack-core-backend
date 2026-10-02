# frozen_string_literal: true

# Polls each 13F form explicitly because EFTS form filters are exact-form filters.
class Edgar13fPoller
  LAST_SUCCESS_KEY = "edgar:poller:13f:last_success_at"

  def self.last_success_at(redis: FilingsIntel.redis)
    EdgarPoller.last_success_at(redis:, key: LAST_SUCCESS_KEY)
  end

  def initialize(search: nil, redis: FilingsIntel.redis)
    @search = search || Edgar::FullTextSearch.new(client: SecClient.new(lane: :form13f))
    @redis = redis
  end

  def poll(dates = default_dates)
    added = Filing::FORM13F_TYPES.flat_map do |form|
      EdgarPoller.new(
        search: @search, redis: @redis, form:, last_success_key: LAST_SUCCESS_KEY
      ).poll(dates)
    end
    @redis.call("SET", LAST_SUCCESS_KEY, Time.current.utc.iso8601)
    added.uniq
  end

  private

  def default_dates
    today = Time.current.in_time_zone(Edgar::Submission::EDGAR_ZONE).to_date
    [ today, today - 1 ]
  end
end
