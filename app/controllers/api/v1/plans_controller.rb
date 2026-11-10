# frozen_string_literal: true

module Api
  module V1
    class PlansController < BaseController
      def index
        read_parameters(allowed: [])
        render json: { data: PlanCatalog::PLANS.map { |id, limits| { id:, limits: } } }
      end
    end
  end
end
