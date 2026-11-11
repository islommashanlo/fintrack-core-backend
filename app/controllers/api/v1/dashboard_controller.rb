# frozen_string_literal: true

module Api
  module V1
    class DashboardController < ProtectedController
      def show
        values = read_parameters(allowed: %w[days limit])
        days = values.fetch("days", "30")
        limit = values.fetch("limit", "5")
        raise InvalidParameter, "Invalid days parameter" unless %w[7 30 90].include?(days)
        raise InvalidParameter, "Invalid limit parameter" unless limit.match?(/\A(?:[1-9]|10)\z/)

        render json: DashboardQuery.new(user: Current.user, days: days.to_i, limit: limit.to_i, as_of:).call
      end
    end
  end
end
