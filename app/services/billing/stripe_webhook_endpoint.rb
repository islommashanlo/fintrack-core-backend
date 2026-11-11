# frozen_string_literal: true

module Billing
  # Rack boundary preserves bytes and verifies them before any JSON parameter parsing.
  class StripeWebhookEndpoint
    MAX_BODY_BYTES = 1_048_576

    def call(env)
      request = ActionDispatch::Request.new(env)
      Configuration.require_webhooks!
      ApiRateLimiter.check!(scope: "stripe_webhooks", identifier: request.remote_ip, limit: 300, window: 1.minute)
      return oversized if request.get_header("CONTENT_LENGTH").to_i > MAX_BODY_BYTES

      body = request.body.read(MAX_BODY_BYTES + 1).to_s
      return oversized if body.bytesize > MAX_BODY_BYTES

      StripeSignature.verify!(body:, header: request.get_header("HTTP_STRIPE_SIGNATURE"), secret: ENV.fetch("STRIPE_WEBHOOK_SECRET"))
      attributes = StripeEvent.parse(body)
      result = ReceiveEvent.call(attributes:, payload_digest: Digest::SHA256.hexdigest(body))
      response(200, data: { received: true, duplicate: result.duplicate })
    rescue StripeSignature::Invalid, StripeEvent::Invalid
      response(400, error: { code: "INVALID_WEBHOOK", message: "Invalid webhook" })
    rescue ReceiveEvent::Conflict
      response(409, error: { code: "EVENT_CONFLICT", message: "Conflicting event identity" })
    rescue ApiRateLimiter::Limited => error
      response(429, { error: { code: "RATE_LIMITED", message: "Too many requests" } }, "retry-after" => error.retry_after.to_s)
    rescue Configuration::Unavailable, ReceiveEvent::QueueUnavailable, ApiRateLimiter::Unavailable, ActiveRecord::ActiveRecordError
      response(503, { error: { code: "TEMPORARILY_UNAVAILABLE", message: "Billing is temporarily unavailable" } }, "retry-after" => "60")
    end

    private

    def oversized
      response(413, error: { code: "PAYLOAD_TOO_LARGE", message: "Webhook payload exceeds the size limit" })
    end

    def response(status, body, headers = {})
      [ status, { "content-type" => "application/json", "cache-control" => "no-store" }.merge(headers), [ JSON.generate(body) ] ]
    end
  end
end
