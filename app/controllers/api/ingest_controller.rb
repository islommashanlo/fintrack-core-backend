# frozen_string_literal: true

module Api
  class IngestController < ActionController::API
    include IngestAuth

    before_action :authenticate_ingest!

    # POST /api/ingest/trades
    def trades
      trades = params.require(:trades)
      created = 0
      ActiveRecord::Base.transaction do
        trades.each do |t|
          trader = Trader.where(name: t[:company_name], trader_type: t[:trader_type]).first_or_create!
          exists = Trade.where(
            trader_id: trader.id,
            ticker: t[:ticker],
            transaction_date: t[:transaction_date],
            filing_url: t[:filing_url]
          ).exists?
          next if exists

          Trade.create!(
            trader_id: trader.id,
            ticker: t[:ticker],
            company_name: t[:company_name],
            transaction_type: t[:transaction_type],
            filing_type: t[:filing_type],
            transaction_date: t[:transaction_date],
            filing_date: t[:filing_date],
            shares: t[:shares],
            price: t[:price],
            value: t[:value],
            filing_url: t[:filing_url]
          )
          created += 1
        end
      end
      render json: { created: created }
    rescue ActionController::ParameterMissing
      render json: { error: 'Invalid payload' }, status: :bad_request
    end
  end
end
