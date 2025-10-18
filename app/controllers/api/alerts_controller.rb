# frozen_string_literal: true

module Api
  class AlertsController < ApplicationController
    include Authenticate

    before_action :authenticate_user!

    def index
      alerts = Current.user.alert_subscriptions.where(is_active: true)
      render json: alerts
    end

    def create
      attrs = alert_params
      existing = Current.user.alert_subscriptions.where(
        trader_id: attrs[:trader_id],
        ticker: attrs[:ticker],
        transaction_type: attrs[:transaction_type],
        is_active: true
      ).first
      return render json: { error: 'Similar alert already exists' }, status: :bad_request if existing

      alert = Current.user.alert_subscriptions.create!(attrs)
      render json: alert, status: :created
    end

    def show
      alert = Current.user.alert_subscriptions.find(params[:id])
      render json: alert
    end

    def update
      alert = Current.user.alert_subscriptions.find(params[:id])
      alert.update!(alert_params)
      render json: alert
    end

    def destroy
      alert = Current.user.alert_subscriptions.find(params[:id])
      alert.update!(is_active: false)
      render json: { message: 'Alert subscription deleted' }
    end

    private

    def alert_params
      params.permit(:trader_id, :ticker, :transaction_type, :min_value, :is_active)
    end
  end
end
