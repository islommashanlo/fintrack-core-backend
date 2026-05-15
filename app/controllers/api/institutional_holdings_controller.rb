# frozen_string_literal: true

module Api
  class InstitutionalHoldingsController < ActionController::API
    include Authenticate

    before_action :authenticate_user!

    # GET /api/institutional_holdings
    def index
      holdings = InstitutionalHolding.all

      holdings = holdings.where(trade_source_id: params[:trade_source_id]) if params[:trade_source_id].present?
      holdings = holdings.for_ticker(params[:ticker].upcase)               if params[:ticker].present?
      holdings = holdings.for_period(params[:period_of_report])            if params[:period_of_report].present?
      holdings = holdings.where('value >= ?', params[:min_value])          if params[:min_value].present?

      total   = holdings.count
      page    = (params[:page] || 1).to_i
      per     = [[( params[:per_page] || 50).to_i, 1].max, 500].min
      offset  = (page - 1) * per

      holdings = holdings.by_value.offset(offset).limit(per).includes(:trade_source)

      render json: {
        holdings:  holdings.map { |h| serialize_holding(h) },
        total:     total,
        page:      page,
        per_page:  per,
        has_next:  (offset + per) < total
      }
    end

    # GET /api/institutional_holdings/:id
    def show
      holding = InstitutionalHolding.includes(:trade_source).find(params[:id])
      render json: serialize_holding(holding)
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Not found' }, status: :not_found
    end

    # GET /api/institutional_holdings/by_ticker?ticker=AAPL
    def by_ticker
      ticker = params.require(:ticker).upcase
      query  = InstitutionalHolding.for_ticker(ticker)
      query  = query.for_period(params[:period_of_report]) if params[:period_of_report].present?

      holdings = query.by_value.limit(200).includes(:trade_source)

      render json: {
        ticker:             ticker,
        period_of_report:   params[:period_of_report],
        total_institutions: holdings.size,
        total_value:        holdings.sum { |h| h.value.to_f },
        total_shares:       holdings.sum { |h| h.shares.to_f },
        holders:            holdings.map { |h| serialize_holder(h) }
      }
    end

    # GET /api/institutional_holdings/top_holders
    def top_holders
      query = InstitutionalHolding
        .select('trade_source_id, SUM(value) AS total_value, COUNT(*) AS position_count')
        .group(:trade_source_id)

      query = query.for_period(params[:period_of_report]) if params[:period_of_report].present?

      rows = query
        .order('total_value DESC')
        .limit([(params[:limit] || 20).to_i, 100].min)

      render json: {
        period_of_report: params[:period_of_report],
        top_holders: rows.map do |row|
          source = TradeSource.find_by(id: row.trade_source_id)
          {
            trade_source_id:  row.trade_source_id,
            institution_name: source&.name,
            institution_type: source&.institution_type,
            total_value:      row.total_value.to_f,
            position_count:   row.position_count
          }
        end
      }
    end

    private

    def serialize_holding(h)
      {
        id:                    h.id,
        trade_source_id:       h.trade_source_id,
        institution_name:      h.trade_source&.name,
        institution_type:      h.trade_source&.institution_type,
        period_of_report:      h.period_of_report,
        ticker:                h.ticker,
        company_name:          h.company_name,
        cusip:                 h.cusip,
        shares:                h.shares,
        value:                 h.value,
        investment_discretion: h.investment_discretion,
        put_call:              h.put_call,
        filing_url:            h.filing_url,
        filing_date:           h.filing_date,
        created_at:            h.created_at
      }
    end

    def serialize_holder(h)
      {
        trade_source_id:  h.trade_source_id,
        institution_name: h.trade_source&.name,
        shares:           h.shares,
        value:            h.value,
        investment_discretion: h.investment_discretion,
        put_call:         h.put_call,
        period_of_report: h.period_of_report
      }
    end
  end
end
