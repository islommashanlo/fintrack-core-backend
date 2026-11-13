# frozen_string_literal: true

module Api
  module V1
    class AuthCapabilitiesController < BaseController
      prepend_before_action :private_response!

      def show
        read_parameters(allowed: [])
        render json: { data: Oauth::Capabilities.call }
      end
    end
  end
end
