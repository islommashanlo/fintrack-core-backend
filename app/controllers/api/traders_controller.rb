# frozen_string_literal: true

module Api
  class TradersController < ApplicationController
    def index
      limit = [params.fetch(:limit, 50).to_i, 100].min
      offset = [params.fetch(:offset, 0).to_i, 0].max
      trade_sources = TradeSource.all
      trade_sources = trade_sources.where(source_type: params[:source_type]) if params[:source_type].present?
      if params[:search].present?
        q = "%#{params[:search]}%"
        trade_sources = trade_sources.where('name ILIKE ?', q)
      end
      trade_sources = trade_sources.order(id: :desc).limit(limit).offset(offset)
      render json: trade_sources.as_json(include: :trades)
    end

    def show
      trade_source = TradeSource.find(params[:id])
      render json: trade_source.as_json(include: :trades)
    end

    def politicians
      limit = [params.fetch(:limit, 50).to_i, 100].min
      trade_sources = TradeSource.politicians
      if params[:search].present?
        q = "%#{params[:search]}%"
        trade_sources = trade_sources.where('name ILIKE ?', q)
      end
      render json: trade_sources.limit(limit)
    end

    def hedge_funds
      limit = [params.fetch(:limit, 50).to_i, 100].min
      trade_sources = TradeSource.hedge_funds
      if params[:search].present?
        q = "%#{params[:search]}%"
        trade_sources = trade_sources.where('name ILIKE ?', q)
      end
      render json: trade_sources.limit(limit)
    end

    def most_active
      limit = [params.fetch(:limit, 10).to_i, 50].min
      days = (params[:days] || 30).to_i
      cutoff = Time.now.utc - days.days
      rows = TradeSource
             .joins(:trades)
             .where('trades.trade_date >= ?', cutoff)
             .group('trade_sources.id')
             .select('trade_sources.*, COUNT(trades.id) AS trade_count, SUM(trades.amount) AS total_value')
             .order('COUNT(trades.id) DESC')
             .limit(limit)
      render json: rows.map { |ts|
        {
          trade_source: ts,
          trade_count: ts.trade_count.to_i,
          total_value: ts.total_value.to_f
        }
      }
    end
  end
end
