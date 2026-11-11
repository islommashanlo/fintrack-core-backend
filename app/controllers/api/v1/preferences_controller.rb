# frozen_string_literal: true

module Api
  module V1
    class PreferencesController < ProtectedController
      def show
        read_parameters(allowed: [])
        render json: { data: UserPreferenceSerializer.render(Current.user.user_preference) }
      end

      def update
        values = read_parameters(allowed: %w[theme dashboard_layout])
        raise InvalidParameter, "At least one preference is required" if values.empty?

        preference = AccountPreferences.update(user: Current.user, attributes: values)
        render json: { data: UserPreferenceSerializer.render(preference) }
      end
    end
  end
end
