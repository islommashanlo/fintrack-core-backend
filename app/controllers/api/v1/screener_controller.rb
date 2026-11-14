# frozen_string_literal: true

module Api
  module V1
    class ScreenerController < BaseController
      before_action :private_response!

      def capabilities
        read_parameters(allowed: [])
        render json: { data: ScreenerCapabilities.call }
      end

      def run
        values = ScreenerParameters.normalize(params.except(:controller, :action, :format).to_unsafe_h)
        result = ScreenerExecution.call(values:, user: Current.user, as_of:)
        render json: { data: result.rows, meta: result.meta }
      end
    end
  end
end
