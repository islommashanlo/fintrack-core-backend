# frozen_string_literal: true

# Live detection of new Form 4 filings through EDGAR full-text search.
#
# Search results are ordered by filing date, not acceptance time, so new filings can land
# anywhere in a day's results. Each poll asks for the first page; if the day's total is
# the one we last saw, nothing is new and that single request is the whole poll.
# Otherwise every page is read and unknown filings are registered.
class EdgarPoller
  ROOT_FORM = "4" # matches 4 and 4/A
  LAST_SUCCESS_KEY = "edgar:poller:last_success_at"
  SEEN_TOTAL_TTL = 3.days.to_i

  def self.last_success_at(redis: FilingsIntel.redis, key: LAST_SUCCESS_KEY)
    value = redis.call("GET", key)
    value && Time.iso8601(value)
  end

  def initialize(search: nil, redis: FilingsIntel.redis, form: ROOT_FORM,
                 last_success_key: LAST_SUCCESS_KEY)
    @search = search || Edgar::FullTextSearch.new(client: SecClient.new(lane: :form4))
    @redis = redis
    @form = form
    @last_success_key = last_success_key
  end

  # Returns the accession numbers that were new. Dates default to today and yesterday
  # in EDGAR's time zone.
  def poll(dates = default_dates)
    added = dates.flat_map { |date| poll_day(date) }
    @redis.call("SET", @last_success_key, Time.current.utc.iso8601)
    added
  end

  private

  def default_dates
    today = Time.current.in_time_zone(Edgar::Submission::EDGAR_ZONE).to_date
    [ today, today - 1 ]
  end

  def poll_day(date)
    first = @search.page(form: @form, date:)
    return [] if first.total == seen_total(date)

    refs = first.refs
    hits = first.hit_count
    while hits < first.total
      page = @search.page(form: ROOT_FORM, date:, from: hits)
      break if page.hit_count.zero?

      refs += page.refs
      hits += page.hit_count
    end

    added = FilingRegistrar.register(refs, source: "efts")
    # Only remember the total once every hit was read; otherwise the next poll re-reads the day.
    remember_total(date, first.total) if hits >= first.total
    added
  end

  def seen_total(date)
    @redis.call("GET", total_key(date))&.to_i
  end

  def remember_total(date, total)
    @redis.call("SET", total_key(date), total, "EX", SEEN_TOTAL_TTL)
  end

  def total_key(date)
    "edgar:poller:total:#{@form}:#{date.iso8601}"
  end
end
