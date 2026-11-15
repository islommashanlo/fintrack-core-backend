# frozen_string_literal: true

module Ops
  class MarketInputsController < ActionController::API
    include ActionController::HttpAuthentication::Basic::ControllerMethods

    before_action :private_response
    before_action :authenticate
    rescue_from ::MarketInputs::PreviewParameters::Invalid, with: :invalid_parameters

    def preview
      values = ::MarketInputs::PreviewParameters.normalize(params.except(:controller, :action, :format).to_unsafe_h)
      policy = ::MarketInputs::PreviewPolicy.load
      result = ::MarketInputs::PairedCandidates.new(**values, **policy.to_h).call
      scale = result.scale&.to_h
      scale = scale.merge(market_cap: result.scale.market_cap&.to_s("F")) if scale
      render json: { data: result.to_h.merge(identity: result.identity.to_h, scale:) }
    end

    private

    def private_response
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["Pragma"] = "no-cache"
    end

    def authenticate
      authenticate_or_request_with_http_basic("FilingsIntel ops") { |user, password| OpsAuth.valid?(user, password) }
    end

    def invalid_parameters
      render json: { error: { code: "INVALID_PARAMETERS", message: "Expected one CUSIP and a nonfuture RFC3339 as_of timestamp" } }, status: :bad_request
    end
  end
end
