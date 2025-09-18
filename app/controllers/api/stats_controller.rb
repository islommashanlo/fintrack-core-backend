module Api
  class StatsController < ApplicationController
    def index
      days = (params[:days] || 30).to_i
      cutoff = Time.now.utc - days.days

      total_scope = Trade.where("transaction_date >= ?", cutoff)
      total_trades = total_scope.count
      total_value = total_scope.sum(:value).to_f

      top_traders = Trader
        .joins(:trades)
        .where("trades.transaction_date >= ?", cutoff)
        .group("traders.id", "traders.name", "traders.trader_type")
        .select("traders.name, traders.trader_type, COUNT(trades.id) AS trade_count, SUM(trades.value) AS total_value")
        .order("trade_count DESC")
        .limit(10)

      top_stocks = Trade
        .where("transaction_date >= ?", cutoff)
        .group(:ticker, :company_name)
        .select("ticker, company_name, COUNT(id) AS trade_count, SUM(value) AS total_value")
        .order("trade_count DESC")
        .limit(10)

      recent_trades = Trade
        .includes(:trader)
        .where("transaction_date >= ?", cutoff)
        .order(filing_date: :desc)
        .limit(20)

      render json: {
        total_trades: total_trades,
        total_value: total_value,
        top_traders: top_traders.map { |r| { name: r.name, trader_type: r.trader_type, trade_count: r.trade_count.to_i, total_value: r.total_value.to_f } },
        top_stocks: top_stocks.map { |r| { ticker: r.ticker, company_name: r.company_name, trade_count: r.trade_count.to_i, total_value: r.total_value.to_f } },
        recent_activity: recent_trades.as_json(include: { trader: { only: [:id, :name, :trader_type, :avatar_url] } })
      }
    end

    def by_type
      days = (params[:days] || 30).to_i
      cutoff = Time.now.utc - days.days

      rows = Trader
        .joins(:trades)
        .where("trades.transaction_date >= ?", cutoff)
        .group("traders.trader_type")
        .select("traders.trader_type, COUNT(trades.id) AS trade_count, SUM(trades.value) AS total_value, AVG(trades.value) AS avg_value")

      render json: rows.map { |r| { trader_type: r.trader_type, trade_count: r.trade_count.to_i, total_value: r.total_value.to_f, avg_value: r.avg_value.to_f } }
    end

    def timeline
      days = (params[:days] || 30).to_i
      cutoff = Time.now.utc - days.days

      rows = Trade
        .where("transaction_date >= ?", cutoff)
        .group("DATE(trades.transaction_date)")
        .select("DATE(trades.transaction_date) AS date, COUNT(trades.id) AS trade_count, SUM(trades.value) AS total_value")
        .order("date ASC")

      render json: rows.map { |r| { date: r.date.to_date.iso8601, trade_count: r.trade_count.to_i, total_value: r.total_value.to_f } }
    end

    def biggest_trades
      limit = [(params[:limit] || 20).to_i, 100].min
      days = (params[:days] || 30).to_i
      cutoff = Time.now.utc - days.days

      trades = Trade
        .joins(:trader)
        .where("trades.transaction_date >= ?", cutoff)
        .where.not(value: nil)
        .order(value: :desc)
        .limit(limit)

      render json: trades
    end
  end
end


