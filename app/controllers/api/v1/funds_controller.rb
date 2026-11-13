# frozen_string_literal: true

module Api
  module V1
    class FundsController < BaseController
      prepend_before_action :private_response!, only: %i[index show holdings history position_history changes turnover news]

      def index
        values = read_parameters(allowed: FundDirectoryQuery::PARAMETERS)
        period_parameter(values["period"])
        query = FundDirectoryQuery.new(parameters: values, history: history_window, as_of:)
        result = query.call
        sources = FundDirectoryQuery.sources(result.records)
        turnover_context = { baseline_policy: result.meta.fetch(:turnover_baseline_policy), methodology_version: result.meta.fetch(:turnover_methodology_version) }
        render json: { data: result.records.map { |fund| FundDirectorySerializer.render(fund, sources:, as_of: query.page.as_of, turnover_context:) }, meta: result.meta }
      end

      def show
        read_parameters(allowed: [], path_keys: [ :cik ])
        render json: FundProfileQuery.new(fund: find_fund, history: history_window, as_of:).call
      end

      def holdings
        fund = find_fund
        values = read_parameters(allowed: %w[period cusip put_call share_type sort limit cursor], path_keys: [ :cik ])
        period = period_parameter(values["period"])
        InstitutionalHoldingsQuery.validate_filters!(values)
        page = report_page(values, "fund_holdings", sorts: InstitutionalHoldingsQuery::SORTS, default_sort: "-value_usd")
        query = InstitutionalHoldingsQuery.new(page:, filters: values)
        scope = query.for_fund(fund, period:)
        history_window.check!(query.period, as_of: page.as_of)
        result = page.call(scope, preload: [ { institutional_report: [ :filing, :institutional_filer ] } ])
        portfolio = FundPortfolioQuery.new(page:, reports: query.reports, fund:, period: query.period).call(result.records)
        result = history_window.decorate(result)
        render json: {
          data: result.records.map do |holding|
            InstitutionalHoldingSerializer.render(holding, as_of: page.as_of).merge(position: portfolio.positions[holding.id.to_s])
          end,
          meta: result.meta.merge(portfolio: portfolio.meta)
        }
      end

      def history
        fund = find_fund
        values = read_parameters(allowed: %w[period sort limit cursor], path_keys: [ :cik ])
        period = period_parameter(values["period"])
        page = report_page(values, "fund_history", sorts: {
          "filed_at" => "COALESCE(filings.filed_at, institutional_reports.filed_at)", "period" => "institutional_reports.period_of_report"
        }, default_sort: "-period")
        history_window.check!(period, as_of: page.as_of)
        scope = report_scope(page).visible_reports.where(institutional_filer_id: fund.id)
        scope = scope.where(period_of_report: period) if period
        result = history_window.preview(page:, scope:, allowed_scope: history_window.reports(scope, as_of: page.as_of), preload: [ :filing ])
        render_read_page(result, InstitutionalReportSerializer)
      end

      def position_history
        fund = find_fund
        values = read_parameters(allowed: %w[cusip put_call share_type period sort limit cursor], path_keys: [ :cik ])
        raise InvalidParameter, "Missing cusip parameter" unless values["cusip"]
        period_parameter(values["period"])
        InstitutionalHoldingsQuery.validate_filters!(values)
        page = report_page(values, "fund_position_history", sorts: FundPositionHistoryQuery::SORTS, default_sort: "-period")
        result = FundPositionHistoryQuery.new(fund:, page:, filters: values, history: history_window).call
        sources = FundPositionHistoryQuery.sources(result.records)
        render json: {
          data: result.records.map { |row| FundPositionHistorySerializer.render(row, sources:, as_of: page.as_of) },
          meta: result.meta.merge(missing_periods_filled: false, disclaimer: FilingsIntel::DISCLAIMER)
        }
      end

      def changes
        fund = find_fund
        values = read_parameters(allowed: %w[period change_type sort limit cursor], path_keys: [ :cik ])
        period = period_parameter(values["period"])
        page = report_page(values, "fund_changes", sorts: PositionChangesQuery::SORTS, default_sort: "-value_change")
        query = PositionChangesQuery.new(fund:, page:, period:, change_type: values["change_type"])
        history_window.check!(query.period, as_of: page.as_of)
        result = history_window.decorate(query.call)
        sources = PositionChangesQuery.sources(result.records)
        portfolios = query.portfolios(result.records)
        render json: {
          data: result.records.map { |change| PositionChangeSerializer.render(change, reports: sources, as_of: page.as_of, portfolios:) },
          meta: result.meta.merge(period_of_report: query.period, prior_period_of_report: query.prior_period,
            current_portfolio: portfolios.fetch(:current).meta, prior_portfolio: portfolios.fetch(:prior).meta)
        }
      end

      def turnover
        values = read_parameters(allowed: %w[period], path_keys: [ :cik ])
        period = period_parameter(values["period"])
        render json: FundTurnoverQuery.new(fund: find_fund, history: history_window, as_of:, period:).call
      end

      def news
        values = read_parameters(allowed: NewsQuery::PARAMETERS, path_keys: [ :cik ])
        render json: NewsQuery.new(parameters: values, target: { role: "fund", cik: find_fund.cik }, as_of:).call
      end

      private

      def find_fund
        InstitutionalFiler.find_by!(cik: params[:cik])
      end

      def report_page(values, resource, sorts:, default_sort:)
        CursorPage.new(parameters: values, context: history_window.context.merge("resource" => resource, "cik" => params[:cik]),
                       sorts:, default_sort:, bounds: InstitutionalHoldingsQuery::BOUNDS, as_of:)
      end

      def history_window
        @history_window ||= HistoryWindow.new(limit: PlanCatalog.limit_for(Current.user, :history_quarters), user_id: Current.user&.id)
      end

      def report_scope(page)
        InstitutionalReportScope.new(as_of: page.as_of, max_report_id: page.bound("reports"),
                                     max_filing_id: page.bound("filings"), max_holding_id: page.bound("holdings"))
      end
    end
  end
end
