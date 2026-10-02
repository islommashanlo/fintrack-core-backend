# frozen_string_literal: true

class TickersController < ApplicationController
  allow_unauthenticated_access

  def show
    profile = TickerProfile.new(ticker: params[:ticker])
    raise ActiveRecord::RecordNotFound unless profile.issuer

    @ticker = params[:ticker].upcase
    @issuer = profile.issuer
    @summary = profile.summary
    @transactions = profile.transactions(limit: 40)
    @institutional_holdings = profile.institutional_holdings(limit: 24)
    @institutional_changes = profile.institutional_changes(limit: 24)
    @institutional_history = profile.institutional_history(periods: 4, limit: 48)
    @smart_money_collisions = SmartMoneyCollisions.new.matches(ticker: @ticker, days: 90, window_days: 45, limit: 8)
  end
end
