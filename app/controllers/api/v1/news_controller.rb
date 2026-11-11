# frozen_string_literal: true

module Api
  module V1
    class NewsController < ProtectedController
      def index
        values = read_parameters(allowed: NewsQuery::PARAMETERS + %w[watchlist])
        if values["watchlist"] && values["watchlist"] != "true"
          raise InvalidParameter, "Only watchlist news is supported at this route"
        end
        render json: NewsQuery.new(parameters: values.except("watchlist"), user: Current.user, as_of:).call
      end
    end
  end
end
