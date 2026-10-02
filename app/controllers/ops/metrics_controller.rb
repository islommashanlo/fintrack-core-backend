# frozen_string_literal: true

module Ops
  # GET /ops/metrics: operator-only JSON, behind the same credentials as Sidekiq Web.
  class MetricsController < ActionController::API
    include ActionController::HttpAuthentication::Basic::ControllerMethods

    before_action :authenticate

    def show
      render json: OpsMetrics.new.to_h
    end

    private

    def authenticate
      authenticate_or_request_with_http_basic("FilingsIntel ops") { |user, password| OpsAuth.valid?(user, password) }
    end
  end
end
