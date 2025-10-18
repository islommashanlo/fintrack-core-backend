# frozen_string_literal: true

class Api::StripeController < ApplicationController
  skip_before_action :authenticate_user!, only: [:webhooks]
  skip_before_action :verify_authenticity_token, only: [:webhooks]

  def webhooks
    payload = request.body.read
    signature = request.headers['HTTP_STRIPE_SIGNATURE']

    begin
      event = StripeService.construct_webhook_event(payload, signature)
      StripeService.handle_webhook_event(event)

      render json: { message: 'Webhook processed successfully' }, status: :ok
    rescue JSON::ParserError
      render json: { error: 'Invalid JSON payload' }, status: :bad_request
    rescue Stripe::SignatureVerificationError
      render json: { error: 'Invalid signature' }, status: :bad_request
    rescue StandardError => e
      render json: { error: e.message }, status: :internal_server_error
    end
  end
end
