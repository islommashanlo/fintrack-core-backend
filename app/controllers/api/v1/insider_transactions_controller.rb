# frozen_string_literal: true

module Api
  module V1
    class InsiderTransactionsController < BaseController
      def index
        result = InsiderTransactionsQuery.new(
          parameters: params.except(:controller, :action, :format).to_unsafe_h, as_of:
        ).call
        timestamp = Time.iso8601(result.meta.fetch(:as_of))

        render json: {
          data: result.records.map { |transaction| InsiderTransactionSerializer.render(transaction, as_of: timestamp) },
          meta: result.meta
        }
      end
    end
  end
end
