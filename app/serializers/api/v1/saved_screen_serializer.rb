# frozen_string_literal: true

module Api
  module V1
    class SavedScreenSerializer
      def self.render(screen, as_of: Time.current)
        { id: screen.id, name: screen.name, definition: screen.definition,
          created_at: screen.created_at, updated_at: screen.updated_at }
      end
    end
  end
end
