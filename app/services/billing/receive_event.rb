# frozen_string_literal: true

module Billing
  class ReceiveEvent
    class Conflict < StandardError; end
    class QueueUnavailable < StandardError; end
    Result = Data.define(:event, :duplicate)

    def self.call(attributes:, payload_digest:)
      known = StripeEvent::TYPES.include?(attributes.fetch(:event_type))
      event = BillingEvent.create_or_find_by!(stripe_id: attributes.fetch(:stripe_id), livemode: attributes.fetch(:livemode)) do |row|
        row.assign_attributes(attributes.merge(payload_digest:, verified_at: Time.current,
          status: known ? "pending" : "ignored", reason: known ? nil : "unsupported_event",
          processed_at: known ? nil : Time.current))
      end
      duplicate = !event.previously_new_record?
      raise Conflict unless attributes.all? { |key, value| event.public_send(key) == value }

      if %w[pending failed].include?(event.status)
        raise QueueUnavailable unless ProcessStripeEventJob.perform_later(event.id)
      end
      Result.new(event:, duplicate:)
    rescue ActiveJob::EnqueueError, RedisClient::Error
      raise QueueUnavailable
    end
  end
end
