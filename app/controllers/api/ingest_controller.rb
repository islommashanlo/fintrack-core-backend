# frozen_string_literal: true

module Api
  class IngestController < ActionController::API
    include IngestAuth

    before_action :authenticate_ingest!

    # POST /api/ingest/trades
    #
    # Accepts a payload of the form:
    #   { trades: [ { company_name:, ticker:, transaction_type:, filing_type:,
    #                 transaction_date:, filing_date:, value:, shares:, price:,
    #                 filing_url:, trader_type: }, ... ] }
    #
    # trader_type must be one of: politician, hedge_fund, insider, institution, hnwi
    def trades
      trades_data = params.require(:trades)
      created = 0

      ActiveRecord::Base.transaction do
        trades_data.each do |t|
          source = TradeSource
            .where(name: t[:company_name], source_type: t[:trader_type])
            .first_or_create!(name: t[:company_name], source_type: t[:trader_type])

          next if Trade.where(
            trade_source_id: source.id,
            ticker: t[:ticker],
            trade_date: t[:transaction_date],
            disclosure_url: t[:filing_url]
          ).exists?

          Trade.create!(
            trade_source_id: source.id,
            ticker:           t[:ticker],
            asset_name:       t[:company_name],
            transaction_type: t[:transaction_type],
            trade_date:       t[:transaction_date],
            filing_date:      t[:filing_date],
            amount:           t[:value],
            disclosure_url:   t[:filing_url]
          )
          created += 1
        end
      end

      render json: { created: created }
    rescue ActionController::ParameterMissing
      render json: { error: 'Invalid payload' }, status: :bad_request
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # POST /api/ingest/institutional_holdings
    #
    # Accepts a payload of the form:
    #   { holdings: [ { institution_name:, institution_cik:, institution_type:,
    #                   period_of_report:, ticker:, company_name:, cusip:,
    #                   shares:, value:, investment_discretion:, put_call:,
    #                   filing_url:, filing_date: }, ... ] }
    def institutional_holdings
      holdings_data = params.require(:holdings)
      created = 0

      ActiveRecord::Base.transaction do
        holdings_data.each do |h|
          source = TradeSource
            .where(name: h[:institution_name], source_type: 'institution')
            .first_or_create! do |s|
              s.name             = h[:institution_name]
              s.source_type      = 'institution'
              s.institution_type = h[:institution_type]
              s.cik              = h[:institution_cik]
            end

          # Update metadata fields if changed
          source.update_columns(
            institution_type: h[:institution_type],
            cik:              h[:institution_cik]
          ) if source.institution_type.blank? && h[:institution_type].present?

          next if InstitutionalHolding.where(
            trade_source_id:  source.id,
            period_of_report: h[:period_of_report],
            ticker:           h[:ticker]
          ).exists?

          InstitutionalHolding.create!(
            trade_source_id:       source.id,
            period_of_report:      h[:period_of_report],
            ticker:                h[:ticker],
            company_name:          h[:company_name],
            cusip:                 h[:cusip],
            shares:                h[:shares],
            value:                 h[:value],
            investment_discretion: h[:investment_discretion],
            put_call:              h[:put_call],
            filing_url:            h[:filing_url],
            filing_date:           h[:filing_date]
          )
          created += 1
        end
      end

      render json: { created: created }
    rescue ActionController::ParameterMissing
      render json: { error: 'Invalid payload' }, status: :bad_request
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end
end
