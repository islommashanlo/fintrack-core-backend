# frozen_string_literal: true

module Api
  module V1
    class SavedScreensQuery
      SORTS = { "name" => "LOWER(saved_screens.name)", "created_at" => "saved_screens.created_at",
                "updated_at" => "saved_screens.updated_at" }.freeze

      def self.call(user:, page:, filters:)
        scope = user.saved_screens.where("saved_screens.id <= ? AND saved_screens.created_at <= ?",
          page.bound("saved_screens"), page.as_of)
        scope = scope.where(entity: filters.fetch("entity")) if filters["entity"]
        if filters["q"]
          scope = scope.where("saved_screens.name ILIKE ?", "%#{SavedScreen.sanitize_sql_like(filters.fetch('q'))}%")
        end
        page.call(scope)
      end
    end
  end
end
