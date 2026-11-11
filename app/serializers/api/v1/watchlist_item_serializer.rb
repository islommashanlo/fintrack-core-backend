# frozen_string_literal: true

module Api
  module V1
    class WatchlistItemSerializer
      def self.render(follow, as_of: Time.current, name: nil)
        {
          id: follow.id, entity_type: WatchlistTarget::API_TYPES.fetch(follow.target_type),
          entity_key: follow.target_key, name: name || follow["entity_name"] || follow.target_key,
          created_at: follow.followed_at
        }
      end
    end
  end
end
