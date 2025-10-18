# frozen_string_literal: true

module Api
  class ProfilesController < ApplicationController
    def show
      trade_source_id = params[:trader_id] || params[:id]
      trade_source = TradeSource.find(trade_source_id)
      render json: trade_source.as_json(include: :trades)
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Trade Source not found' }, status: :not_found
    end

    def stats
      trade_source_id = params[:trader_id] || params[:id]
      trade_source = TradeSource.find(trade_source_id)
      stats = Trade.where(trade_source_id: trade_source.id)
                   .select('COUNT(id) AS total_trades, SUM(amount) AS total_value, AVG(amount) AS avg_trade_value')
                   .take

      most_traded = Trade.where(trade_source_id: trade_source.id)
                         .group(:ticker)
                         .select('ticker, COUNT(id) AS trade_count')
                         .order('trade_count DESC')
                         .take

      recent_trades = Trade.where(trade_source_id: trade_source.id)
                           .order(trade_date: :desc)
                           .limit(10)

      render json: {
        total_trades: stats.total_trades.to_i,
        total_value: stats.total_value.to_f,
        avg_trade_value: stats.avg_trade_value.to_f,
        most_traded_stock: most_traded&.ticker,
        recent_trades: recent_trades.as_json(include: :trade_source)
      }
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Trade Source not found' }, status: :not_found
    end
  end
end
