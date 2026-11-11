# frozen_string_literal: true

module Api
  module V1
    class BaseController < ActionController::Base
      include Authentication
      include SessionManagement
      wrap_parameters false
      allow_unauthenticated_access
      before_action :enforce_request_limits
      protect_from_forgery with: :exception
      self.forgery_protection_origin_check = true

      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
      rescue_from InvalidParameter, with: :render_invalid_parameter
      rescue_from ActionController::InvalidAuthenticityToken, with: :render_invalid_csrf
      rescue_from ActiveRecord::RecordInvalid, with: :render_invalid_record
      rescue_from ApiRateLimiter::Limited, with: :render_rate_limited
      rescue_from ApiRateLimiter::Unavailable, with: :render_limiter_unavailable
      rescue_from PlanCatalog::Required, with: :render_pro_required
      rescue_from AlertRuleControl::InvalidConfiguration do |error|
        render json: { error: { code: "ALERT_CONFIGURATION_REQUIRED", message: error.message } }, status: :unprocessable_entity
      end

      private

      def render_not_found
        render json: { error: { code: "NOT_FOUND", message: "Resource not found" } }, status: :not_found
      end

      def request_authentication
        render json: { error: { code: "UNAUTHENTICATED", message: "Sign in to continue" } }, status: :unauthorized
      end

      def valid_request_origin?
        return true if request.origin.present? && request.origin == Middleware::ApiCors.origin

        super
      end

      def private_response!
        response.headers["Cache-Control"] = "no-store"
      end

      def enforce_request_limits
        ApiRateLimiter.check!(scope: "ip", identifier: request.remote_ip, limit: 300, window: 1.minute)
        ApiRateLimiter.check!(scope: "user", identifier: Current.user.id, limit: 300, window: 1.minute) if Current.user
      end

      def render_invalid_csrf
        render json: { error: { code: "INVALID_CSRF_TOKEN", message: "Refresh the CSRF token and try again" } }, status: :forbidden
      end

      def render_invalid_record(error)
        details = error.record.errors.to_hash.transform_keys { |key| key == :email_address ? :email : key }
        render json: { error: { code: "VALIDATION_FAILED", message: "Invalid details", details: } }, status: :unprocessable_entity
      end

      def render_rate_limited(error)
        response.headers["Retry-After"] = error.retry_after.to_s
        render json: { error: { code: "RATE_LIMITED", message: "Too many requests" } }, status: :too_many_requests
      end

      def render_limiter_unavailable
        response.headers["Retry-After"] = "1"
        render json: { error: { code: "TEMPORARILY_UNAVAILABLE", message: "Service temporarily unavailable" } }, status: :service_unavailable
      end

      def render_pro_required(error)
        render json: { code: "PRO_REQUIRED", feature: error.feature, limit: error.limit }, status: :payment_required
      end

      def require_parameters!(values, *keys)
        keys.each { |key| raise InvalidParameter, "Missing #{key} parameter" unless values[key].present? }
      end

      def as_of
        @as_of ||= Time.current
      end

      def render_invalid_parameter(error)
        render json: { error: { code: "INVALID_PARAMETER", message: error.message } }, status: :bad_request
      end

      def read_parameters(allowed:, path_keys: [], integer_keys: [])
        values = params.except(:controller, :action, :format, *path_keys).to_unsafe_h
        integer_keys.each { |key| values[key] = values[key].to_s if values[key].is_a?(Integer) }
        values.each do |key, value|
          unless allowed.include?(key) && value.is_a?(String) && value.present?
            raise InvalidParameter, "Invalid #{key} parameter"
          end
        end
        values
      end

      def render_read_page(result, serializer)
        timestamp = Time.iso8601(result.meta.fetch(:as_of))
        render json: { data: result.records.map { |record| serializer.render(record, as_of: timestamp) }, meta: result.meta }
      end

      def period_parameter(value)
        return unless value

        date = Date.iso8601(value)
        raise Date::Error unless value == date.iso8601 && date == date.end_of_quarter

        date
      rescue Date::Error
        raise InvalidParameter, "Invalid period parameter"
      end
    end
  end
end
