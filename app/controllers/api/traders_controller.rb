module Api
  class TradersController < ApplicationController
    def index
      limit = [params.fetch(:limit, 50).to_i, 100].min
      offset = [params.fetch(:offset, 0).to_i, 0].max
      traders = Trader.where(is_active: true)
      traders = traders.where(trader_type: params[:trader_type]) if params[:trader_type].present?
      if params[:search].present?
        q = "%#{params[:search]}%"
        traders = traders.where("name ILIKE ? OR company ILIKE ? OR fund_name ILIKE ?", q, q, q)
      end
      traders = traders.order(id: :desc).limit(limit).offset(offset)
      render json: traders
    end

    def show
      trader = Trader.find(params[:id])
      render json: trader
    end

    def politicians
      limit = [params.fetch(:limit, 50).to_i, 100].min
      traders = Trader.where(trader_type: "politician", is_active: true)
      traders = traders.where("party ILIKE ?", "%#{params[:party]}%") if params[:party].present?
      traders = traders.where("state ILIKE ?", "%#{params[:state]}%") if params[:state].present?
      render json: traders.limit(limit)
    end

    def hedge_funds
      limit = [params.fetch(:limit, 50).to_i, 100].min
      traders = Trader.where(trader_type: "hedge_fund", is_active: true)
      render json: traders.limit(limit)
    end

    def most_active
      limit = [params.fetch(:limit, 10).to_i, 50].min
      days = (params[:days] || 30).to_i
      cutoff = Time.now.utc - days.days
      rows = Trader
        .joins(:trades)
        .where("trades.transaction_date >= ?", cutoff)
        .group("traders.id")
        .select("traders.*, COUNT(trades.id) AS trade_count, SUM(trades.value) AS total_value")
        .order("COUNT(trades.id) DESC")
        .limit(limit)
      render json: rows.map { |t| { trader: t, trade_count: t.trade_count.to_i, total_value: t.total_value.to_f } }
    end
  end
end


