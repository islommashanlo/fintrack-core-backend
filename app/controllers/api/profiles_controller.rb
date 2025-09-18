module Api
  class ProfilesController < ApplicationController
    def show
      trader_id = params[:trader_id] || params[:id]
      trader = Trader.find(trader_id)
      render json: trader
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Trader not found" }, status: :not_found
    end

    def stats
      trader_id = params[:trader_id] || params[:id]
      trader = Trader.find(trader_id)
      stats = Trade.where(trader_id: trader.id)
                   .select("COUNT(id) AS total_trades, SUM(value) AS total_value, AVG(value) AS avg_trade_value")
                   .take

      most_traded = Trade.where(trader_id: trader.id)
                         .group(:ticker)
                         .select("ticker, COUNT(id) AS trade_count")
                         .order("trade_count DESC")
                         .take

      recent_trades = Trade.where(trader_id: trader.id)
                           .order(transaction_date: :desc)
                           .limit(10)

      render json: {
        total_trades: stats.total_trades.to_i,
        total_value: stats.total_value.to_f,
        avg_trade_value: stats.avg_trade_value.to_f,
        most_traded_stock: most_traded&.ticker,
        recent_trades: recent_trades
      }
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Trader not found" }, status: :not_found
    end
  end
end


