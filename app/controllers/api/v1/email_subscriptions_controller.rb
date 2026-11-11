# frozen_string_literal: true

module Api
  module V1
    class EmailSubscriptionsController < BaseController
      skip_before_action :resume_session
      skip_forgery_protection only: :destroy
      before_action :private_response!
      rescue_from EmailUnsubscribe::InvalidToken do
        render json: { error: { code: "INVALID_UNSUBSCRIBE_TOKEN", message: "This unsubscribe link is invalid or expired" } }, status: :not_found
      end

      def show
        EmailUnsubscribe.resolve(params[:token])
        render "email_subscriptions/show", formats: [ :html ], layout: false
      end

      def destroy
        raise InvalidParameter, "Invalid unsubscribe request" unless params["List-Unsubscribe"] == "One-Click"
        EmailUnsubscribe.disable(params[:token])
        render json: { data: { email_enabled: false } }
      end
    end
  end
end
