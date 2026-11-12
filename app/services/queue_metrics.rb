# frozen_string_literal: true

require "yaml"
require "json"
require "sidekiq"

# Bounded operator observations. Never enumerates ready jobs or mutates Sidekiq data.
class QueueMetrics
  SAMPLE_LIMIT = 100
  SETS = { "retry" => "retry", "scheduled" => "schedule", "dead" => "dead" }.freeze

  def initialize(now: Time.current)
    @now = now
  end

  def to_h
    names = queue_names
    values = Sidekiq.redis do |redis|
      redis.pipelined do |pipeline|
        names.each do |name|
          pipeline.call("LLEN", "queue:#{name}")
          pipeline.call("LINDEX", "queue:#{name}", -1)
        end
        SETS.each_value do |key|
          pipeline.call("ZCARD", key)
          pipeline.call("ZRANGE", key, 0, SAMPLE_LIMIT - 1)
          pipeline.call("ZCOUNT", key, "-inf", @now.to_f) unless key == "dead"
        end
      end
    end
    ready = names.to_h do |name|
      size, tail = values.shift(2)
      [ name, ready_metrics(size, tail) ]
    end
    sets = SETS.to_h do |name, key|
      size, sample = values.shift(2)
      due = values.shift unless key == "dead"
      [ name, set_metrics(size, sample, due, names) ]
    end
    { ready:, sets:, workers_checked: false, unknown_ready_queues_checked: false }
  end

  private

  def queue_names
    sec = YAML.safe_load_file(Rails.root.join("config/sidekiq.yml"), permitted_classes: [ Symbol ]).fetch(:queues)
    (sec.map { |entry| entry.is_a?(Array) ? entry.first.to_s : entry.to_s } + NotificationWorkers::QUEUES.map(&:first)).uniq
  end

  def ready_metrics(size, tail)
    return ready_result(size, "changed_during_read") if size.zero? != tail.nil?
    return ready_result(size, "empty") if size.zero?
    job = payload(tail)
    return ready_result(size, "invalid_payload") unless job
    field = job["enqueued_at"].nil? ? "created_at" : "enqueued_at"
    stamp = job[field]
    return ready_result(size, "missing_timestamp") if stamp.nil?
    # Sidekiq 8 stores integer milliseconds; older payloads use floating seconds.
    return ready_result(size, "invalid_timestamp") unless (stamp.is_a?(Integer) || stamp.is_a?(Float)) && stamp.finite? && stamp.positive?
    seconds = stamp.is_a?(Integer) ? stamp / 1000.0 : stamp
    age = @now.to_f - seconds
    return ready_result(size, "future_timestamp") if age.negative?

    ready_result(size, "known", age.round, field)
  end

  def ready_result(size, status, age = nil, field = nil)
    { size:, tail_age_seconds: age, latency_status: status, timestamp_source: field }
  end

  def payload(raw)
    parsed = JSON.parse(raw)
    parsed if parsed.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def set_metrics(size, sample, due, names)
    counts = (names + [ "other" ]).to_h { |name| [ name, 0 ] }
    malformed, unattributed = 0, 0
    sample.each do |raw|
      job = payload(raw)
      if !job
        malformed += 1
      elsif !job["queue"].is_a?(String) || job["queue"].empty?
        unattributed += 1
      else
        counts[names.include?(job["queue"]) ? job["queue"] : "other"] += 1
      end
    end
    complete = size == sample.size && malformed.zero? && unattributed.zero?
    { total_count: size, due_count: due, sampled_count: sample.size, sample_limit: SAMPLE_LIMIT,
      truncated: size > sample.size, counts_complete: complete, sample_selection: "lowest_score_first",
      malformed_payloads: malformed, unattributed_payloads: unattributed,
      by_queue: counts.transform_values { |observed| { observed:, total: complete ? observed : nil } } }
  end
end
