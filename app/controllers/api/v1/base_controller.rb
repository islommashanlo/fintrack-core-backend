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
        @as_of ||= Time.current
      end

      def render_invalid_parameter(error)
        render json: { error: { code: "INVALID_PARAMETER", message: error.message } }, status: :bad_request
      end

      def read_parameters(allowed:, path_keys: [])
        values = params.except(:controller, :action, :format, *path_keys).to_unsafe_h
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
