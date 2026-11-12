# frozen_string_literal: true

module Api
  module V1
    class PushSubscriptionsController < ProtectedController
      rescue_from PushSubscriptionStore::EndpointTaken do
        render json: { error: { code: "PUSH_SUBSCRIPTION_CONFLICT", message: "This device registration is unavailable" } }, status: :conflict
      end
      rescue_from PushSubscriptionStore::LimitReached do
        render json: { error: { code: "PUSH_SUBSCRIPTION_LIMIT", message: "Revoke an existing device registration first", limit: PushSubscriptionStore::MAXIMUM } }, status: :unprocessable_entity
      end
      rescue_from ActiveSupport::MessageEncryptor::InvalidMessage do
        render json: { error: { code: "PUSH_SUBSCRIPTION_UNAVAILABLE", message: "Revoke and register this device again" } }, status: :service_unavailable
      end

      def index
        values = read_parameters(allowed: %w[sort limit cursor])
        page = CursorPage.new(parameters: values, context: { "resource" => "push_subscriptions", "user_id" => Current.user.id, "session_id" => Current.session.id },
          sorts: { "created_at" => "push_subscriptions.created_at" }, default_sort: "-created_at",
          bounds: { "subscriptions" => Current.user.push_subscriptions }, as_of:)
        result = page.call(Current.user.push_subscriptions.where("id <= ? AND created_at <= ?", page.bound("subscriptions"), page.as_of), preload: [ :session ])
        render json: { data: result.records.map { |record| PushSubscriptionSerializer.render(record, session_id: Current.session.id, as_of: page.as_of) }, meta: result.meta.merge(capabilities) }
      end

      def create
        values = params.except(:controller, :action, :format).to_unsafe_h
        result = PushSubscriptionStore.register(user: Current.user, session: Current.session, values:)
        render json: { data: PushSubscriptionSerializer.render(result.record, session_id: Current.session.id), meta: capabilities }, status: result.created ? :created : :ok
      end

      def destroy
        read_parameters(allowed: [], path_keys: [ :id ])
        id = params[:id].to_s
        raise InvalidParameter, "Invalid push subscription ID" unless id.match?(/\A[1-9][0-9]{0,17}\z/)
        PushSubscriptionStore.revoke(user: Current.user, id:)
        head :no_content
      end

      private

      def capabilities
        { registration_enabled: true, delivery_enabled: false, maximum_subscriptions: PushSubscriptionStore::MAXIMUM }
      end
    end
  end
end
