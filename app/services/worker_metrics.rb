# frozen_string_literal: true

require "json"
require "sidekiq"

# Observes Sidekiq metadata without ProcessSet's cleanup or exposing identities.
class WorkerMetrics
  SAMPLE_LIMIT = 100
  HEARTBEAT_SECONDS = 60

  def initialize(queues:, now: Time.current)
    @queues, @now = queues, now
  end

  def to_h
    total, cursor, keys, rows = Sidekiq.redis do |redis|
      count = redis.call("SCARD", "processes")
      position, members = redis.call("SSCAN", "processes", "0", "COUNT", SAMPLE_LIMIT)
      selected = members.uniq.first(SAMPLE_LIMIT)
      values = selected.empty? ? [] : redis.pipelined do |pipeline|
        selected.each { |key| pipeline.call("HMGET", key, "info", "beat", "quiet") }
      end
      [ count, position, selected, values ]
    end
    states = Hash.new(0)
    consumers = @queues.to_h { |queue| [ queue, 0 ] }
    rows.each do |info, beat, quiet|
      state, queues = observation(info, beat, quiet)
      states[state] += 1
      queues.each { |queue| consumers[queue] += 1 if consumers.key?(queue) } if state == "active"
    end
    complete = cursor.to_s == "0" && total == keys.size
    coverage_complete = complete && %w[missing invalid future].all? { |state| states[state].zero? }
    { checked: true, registered_count: total, sampled_count: rows.size, sample_limit: SAMPLE_LIMIT,
      complete:, heartbeat_seconds: HEARTBEAT_SECONDS,
      states: %w[active quiet stale future missing invalid].to_h { |state| [ state, states[state] ] },
      queues: consumers.transform_values { |count| { observed_active_consumers: count, coverage_complete: coverage_complete } } }
  end

  private

  def observation(info, beat, quiet)
    return [ "missing", [] ] if info.nil?
    data = JSON.parse(info)
    return [ "invalid", [] ] unless data.is_a?(Hash) && data["queues"].is_a?(Array) && data["queues"].all? { |queue| queue.is_a?(String) } && %w[true false].include?(quiet)
    stamp = Float(beat, exception: false)
    return [ "invalid", [] ] unless stamp&.finite? && stamp.positive?
    age = @now.to_f - stamp
    state = if age.negative?
      "future"
    elsif age > HEARTBEAT_SECONDS
      "stale"
    else
      quiet == "true" ? "quiet" : "active"
    end
    [ state, data.fetch("queues").uniq ]
  rescue JSON::ParserError
    [ "invalid", [] ]
  end
end
