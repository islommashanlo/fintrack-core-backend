# frozen_string_literal: true

module Api
  module V1
    class MethodologyController < BaseController
      def show
        read_parameters(allowed: [])
        render json: { data: ActivityMethodology.definition }
      end
    end
  end
end
