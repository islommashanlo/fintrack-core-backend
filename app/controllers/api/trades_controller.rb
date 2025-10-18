# frozen_string_literal: true

module Api
  class TradesController < ApplicationController
    def index
      scope = Trade.joins(:trade_source).includes(:trade_source)
      scope = scope.where('trades.ticker ILIKE ?', "%#{params[:ticker]}%") if params[:ticker].present?
      scope = scope.where(trade_source_id: params[:trade_source_id]) if params[:trade_source_id].present?
      scope = scope.where('trade_sources.source_type = ?', params[:source_type]) if params[:source_type].present?
      scope = scope.where(transaction_type: params[:transaction_type]) if params[:transaction_type].present?
      scope = scope.where('trades.trade_date >= ?', params[:start_date]) if params[:start_date].present?
      scope = scope.where('trades.trade_date <= ?', params[:end_date]) if params[:end_date].present?
      scope = scope.where('trades.amount >= ?', params[:min_amount].to_f) if params[:min_amount].present?
      scope = scope.where('trades.amount <= ?', params[:max_amount].to_f) if params[:max_amount].present?

      total = scope.count
      limit = [params.fetch(:limit, 50).to_i, 100].min
      offset = [params.fetch(:offset, 0).to_i, 0].max
      trades = scope.order('trades.trade_date DESC').limit(limit).offset(offset)
      page = (offset / limit) + 1
      has_next = (offset + limit) < total

      render json: {
        trades: trades.as_json(include: {
                                 trade_source: { only: %i[id name source_type] }
                               }),
        total: total,
        page: page,
        per_page: limit,
        has_next: has_next
      }
    end

    def show
      trade = Trade.find(params[:id])
      render json: trade.as_json(include: :trade_source)
    end

    def recent
      limit = [params.fetch(:limit, 10).to_i, 50].min
      trades = Trade.joins(:trade_source).order(filing_date: :desc).limit(limit)
      render json: trades.as_json(include: { trade_source: { only: %i[id name source_type] } })
    end

    def search
      q = params.require(:q)
      limit = [params.fetch(:limit, 20).to_i, 50].min
      trades = Trade
               .joins(:trade_source)
               .where('trade_sources.name ILIKE :q OR trades.asset_name ILIKE :q OR trades.ticker ILIKE :q', q: "%#{q}%")
               .order('trades.trade_date DESC')
               .limit(limit)
      render json: trades.as_json(include: { trade_source: { only: %i[id name source_type] } })
    end
  end
end
