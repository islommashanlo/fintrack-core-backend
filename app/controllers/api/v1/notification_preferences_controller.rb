# frozen_string_literal: true

module Api
  module V1
    class NotificationPreferencesController < ProtectedController
      def show
        read_parameters(allowed: [])
        render_preference(Current.user.notification_preference)
      end

      def update
        values = params.except(:controller, :action, :format).to_unsafe_h
        invalid! unless values.any? && (values.keys - %w[time_zone email_enabled push_enabled]).empty?
        if values.key?("time_zone")
          zone = values["time_zone"]
          invalid! unless zone.nil? || (zone.is_a?(String) && zone.present? && zone.bytesize <= 100 && !zone.include?("\0"))
        end
        invalid! if values.key?("email_enabled") && ![ true, false ].include?(values["email_enabled"])
        invalid! if values.key?("push_enabled") && ![ true, false ].include?(values["push_enabled"])
        preference = NotificationPreferences.update(user: Current.user, attributes: values)
        render_preference(preference)
      end

      private

      def render_preference(preference)
        render json: { data: { time_zone: preference&.time_zone, email_enabled: preference&.email_enabled? || false,
          push_enabled: preference&.push_enabled? || false, push: PushChannelEligibility.call(user: Current.user, session: Current.session),
          digest_local_time: "07:00", configured: preference&.time_zone.present? } }
      end

      def invalid!
        raise InvalidParameter, "Invalid notification preferences"
      end
    end
  end
end
