# frozen_string_literal: true

module Api
  module V1
    class PushSubscriptionSerializer
      def self.render(record, session_id:, as_of: Time.current)
        { id: record.id, endpoint_origin: record.endpoint_origin, expires_at: record.expires_at,
          consented_at: record.consented_at, created_at: record.created_at, updated_at: record.updated_at,
          active: record.active_at?(as_of), current_session: record.session_id == session_id }
      end
    end
  end
end
