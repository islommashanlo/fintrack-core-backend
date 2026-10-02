# frozen_string_literal: true

class TickersController < ApplicationController
  def show
    profile = TickerProfile.new(ticker: params[:ticker])
    raise ActiveRecord::RecordNotFound unless profile.issuer

    @ticker = params[:ticker].upcase
    @issuer = profile.issuer
    @summary = profile.summary
    @transactions = profile.transactions(limit: 40)
    @institutional_holdings = profile.institutional_holdings(limit: 24)
  end
end
