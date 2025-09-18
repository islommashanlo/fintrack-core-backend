module Api
  class TradesController < ApplicationController
    def index
      scope = Trade.joins(:trader).includes(:trader)
      scope = scope.where("trades.ticker ILIKE ?", "%#{params[:ticker]}%") if params[:ticker].present?
      scope = scope.where(trader_id: params[:trader_id]) if params[:trader_id].present?
      scope = scope.where("traders.trader_type = ?", params[:trader_type]) if params[:trader_type].present?
      scope = scope.where(transaction_type: params[:transaction_type]) if params[:transaction_type].present?
      scope = scope.where("trades.transaction_date >= ?", params[:start_date]) if params[:start_date].present?
      scope = scope.where("trades.transaction_date <= ?", params[:end_date]) if params[:end_date].present?
      scope = scope.where("trades.value >= ?", params[:min_value].to_f) if params[:min_value].present?
      scope = scope.where("trades.value <= ?", params[:max_value].to_f) if params[:max_value].present?

      total = scope.count
      limit = [params.fetch(:limit, 50).to_i, 100].min
      offset = [params.fetch(:offset, 0).to_i, 0].max
      trades = scope.order("trades.transaction_date DESC").limit(limit).offset(offset)
      page = (offset / limit) + 1
      has_next = (offset + limit) < total

      render json: { trades: trades.as_json(include: { trader: { only: [:id, :name, :trader_type, :avatar_url] } }), total: total, page: page, per_page: limit, has_next: has_next }
    end

    def show
      trade = Trade.find(params[:id])
      render json: trade
    end

    def recent
      limit = [params.fetch(:limit, 10).to_i, 50].min
      trades = Trade.joins(:trader).order(filing_date: :desc).limit(limit)
      render json: trades
    end

    def search
      q = params.require(:q)
      limit = [params.fetch(:limit, 20).to_i, 50].min
      trades = Trade
        .joins(:trader)
        .where("traders.name ILIKE :q OR trades.company_name ILIKE :q OR trades.ticker ILIKE :q", q: "%#{q}%")
        .order("trades.transaction_date DESC")
        .limit(limit)
      render json: trades
    end
  end
end


