# frozen_string_literal: true

module Api
  module V1
    class ExportsController < ProtectedController
      before_action :require_export_access
      rescue_from CsvDocument::TooLarge do
        render json: { error: { code: "EXPORT_TOO_LARGE", message: "Narrow the filters or reduce limit; the export exceeds 10 MiB" } },
          status: :unprocessable_entity
      end

      def show
        dataset = params[:dataset]
        allowed = ExportQuery::PARAMETERS[dataset] || raise(ActiveRecord::RecordNotFound)
        values = read_parameters(allowed:, path_keys: [ :dataset ])
        result = ExportQuery.new(dataset:, parameters: values, user: Current.user, as_of:).call
        render_export(dataset:, result:)
      end

      def screener
        values = ScreenerParameters.normalize(params.except(:controller, :action, :format).to_unsafe_h,
          maximum_limit: ExportQuery::MAX_ROWS, default_limit: ExportQuery::MAX_ROWS)
        result = ScreenerExecution.call(values:, user: Current.user, as_of:, export: true)
        render_export(dataset: "screener-#{values.fetch('entity')}", result:)
      end

      private

      def render_export(dataset:, result:)
        body = CsvDocument.render(dataset:, rows: result.rows)
        response.headers.merge!(
          "X-Export-Row-Count" => result.rows.length.to_s, "X-Export-Total-Count" => result.meta.fetch(:total_count).to_s,
          "X-Export-Has-More" => result.meta.fetch(:has_more).to_s, "X-Export-As-Of" => result.meta.fetch(:as_of),
          "X-Export-Sort" => result.meta.fetch(:sort), "X-Export-Row-Limit" => ExportQuery::MAX_ROWS.to_s)
        response.headers["X-Export-Next-Cursor"] = result.meta[:next_cursor] if result.meta[:next_cursor]
        send_data body, type: "text/csv; charset=utf-8", disposition: "attachment",
          filename: "filingsintel-#{dataset}-#{Time.iso8601(result.meta.fetch(:as_of)).utc.strftime('%Y%m%dT%H%M%SZ')}.csv"
      end

      def require_export_access
        unless PlanCatalog.limit_for(Current.user, :csv_export)
          raise PlanCatalog::Required.new(feature: "csv_export", limit: 0)
        end
        ApiRateLimiter.check!(scope: "export_user", identifier: Current.user.id, limit: 10, window: 1.minute)
        ApiRateLimiter.check!(scope: "export_ip", identifier: request.remote_ip, limit: 30, window: 1.minute)
      end
    end
  end
end
