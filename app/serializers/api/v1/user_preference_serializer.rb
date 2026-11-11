# frozen_string_literal: true

module Api
  module V1
    class UserPreferenceSerializer
      def self.render(preference)
        preference ||= UserPreference.new
        { theme: preference.theme, dashboard_layout: preference.dashboard_layout }
      end
    end
  end
end
