# frozen_string_literal: true

module Api
  module V1
    class BaseController < ActionController::API
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from InvalidParameter, with: :render_invalid_parameter

      private

      def render_not_found
        render json: { error: { code: "NOT_FOUND", message: "Resource not found" } }, status: :not_found
      end

      def as_of
        Time.current
      end

      def render_invalid_parameter(error)
        render json: { error: { code: "INVALID_PARAMETER", message: error.message } }, status: :bad_request
      end
    end
  end
end
