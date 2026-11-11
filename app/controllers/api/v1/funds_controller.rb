# frozen_string_literal: true

module Api
  module V1
    class FundsController < BaseController
      prepend_before_action :private_response!, only: %i[holdings history changes news]

      def index
        values = read_parameters(allowed: %w[q sort limit cursor])
        page = CursorPage.new(parameters: values, context: { "resource" => "funds" },
                              sorts: { "name" => "LOWER(institutional_filers.name)", "cik" => "institutional_filers.cik" },
                              default_sort: "name", bounds: { "funds" => InstitutionalFiler }, as_of:)
        scope = InstitutionalFiler.where("id <= ?", page.bound("funds"))
        scope = scope.where("name ILIKE ? OR cik = ?", "%#{ApplicationRecord.sanitize_sql_like(values['q'])}%", values["q"]) if values["q"]
        render_read_page(page.call(scope), FundSerializer)
      end

      def show
        read_parameters(allowed: [], path_keys: [ :cik ])
        fund = find_fund
        report = InstitutionalReportScope.new(as_of:).visible_reports
          .where(institutional_filer_id: fund.id).order(period_of_report: :desc)
          .order(Arel.sql("known_filed_at DESC, known_accession DESC")).preload(:filing).first
        render json: { data: FundSerializer.render(fund).merge(
          latest_report: report && InstitutionalReportSerializer.render(report, as_of:)
        ) }
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
        render_read_page(history_window.decorate(result), InstitutionalHoldingSerializer)
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

      def changes
        fund = find_fund
        values = read_parameters(allowed: %w[period change_type sort limit cursor], path_keys: [ :cik ])
        period = period_parameter(values["period"])
        page = report_page(values, "fund_changes", sorts: PositionChangesQuery::SORTS, default_sort: "-value_change")
        query = PositionChangesQuery.new(fund:, page:, period:, change_type: values["change_type"])
        history_window.check!(query.period, as_of: page.as_of)
        result = history_window.decorate(query.call)
        sources = PositionChangesQuery.sources(result.records)
        render json: {
          data: result.records.map { |change| PositionChangeSerializer.render(change, reports: sources, as_of: page.as_of) },
          meta: result.meta
        }
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
