# frozen_string_literal: true

module Api
  module V1
    class WatchlistController < ProtectedController
      def index
        values = read_parameters(allowed: %w[entity_type sort limit cursor])
        page = CursorPage.new(parameters: values, context: { "resource" => "watchlist", "user_id" => Current.user.id },
                              sorts: WatchlistQuery::SORTS, default_sort: "-created_at", bounds: { "follows" => Follow }, as_of:)
        result = WatchlistQuery.call(user: Current.user, page:, entity_type: values["entity_type"])
        render_read_page(result, WatchlistItemSerializer)
      end

      def create
        values = read_parameters(allowed: %w[entity_type entity_key])
        require_parameters!(values, "entity_type", "entity_key")
        target = WatchlistTarget.resolve(type: values["entity_type"], key: values["entity_key"])
        result = WatchlistMembership.add(user: Current.user, target:)
        render json: { data: WatchlistItemSerializer.render(result.follow, name: target.label) }, status: result.created ? :created : :ok
      end

      def destroy
        values = read_parameters(allowed: %w[id], integer_keys: %w[id])
        require_parameters!(values, "id")
        raise InvalidParameter, "Invalid id parameter" unless values["id"].match?(/\A[1-9]\d*\z/)

        WatchlistMembership.remove(user: Current.user, id: values["id"])
        head :no_content
      end
    end
  end
end
