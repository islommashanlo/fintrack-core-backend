# frozen_string_literal: true

class SavedScreenStore
  def self.require_access!(user)
    return if PlanCatalog.limit_for(user, :saved_screens) == true

    raise PlanCatalog::Required.new(feature: "saved_screens", limit: 0)
  end

  def self.create(user:, attributes:)
    user.with_lock do
      require_access!(user)
      definition = SavedScreenDefinition.normalize(attributes.fetch(:definition))
      user.saved_screens.create!(**definition.symbolize_keys, name: attributes.fetch(:name))
    end
  end

  def self.update(user:, id:, attributes:)
    user.with_lock do
      require_access!(user)
      screen = user.saved_screens.find(id)
      screen.assign_attributes(SavedScreenDefinition.normalize(attributes.fetch(:definition))) if attributes.key?(:definition)
      # Replacing a company/insider query with a fund query clears the old window.
      screen.window_days = nil if attributes[:definition] && screen.entity == "funds"
      screen.name = attributes.fetch(:name) if attributes.key?(:name)
      screen.save!
      screen
    end
  end

  def self.destroy(user:, id:)
    user.with_lock do
      require_access!(user)
      user.saved_screens.find(id).destroy!
    end
  end
end
