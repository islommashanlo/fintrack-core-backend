# frozen_string_literal: true

module Api
  module V1
    # Gate selected report quarters and final lists, keeping calculation inputs intact.
    class HistoryWindow
      def initialize(limit:, user_id: nil)
        @limit, @user_id = limit, user_id
      end

      def context
        { "user_id" => @user_id, "history_quarters" => @limit }
      end

      def earliest(as_of:)
        return unless @limit
        ((as_of.to_date.beginning_of_quarter - 1.day) << ((@limit - 1) * 3)).end_of_quarter
      end

      def check!(period, as_of:)
        if period && @limit && period < earliest(as_of:)
          raise PlanCatalog::Required.new(feature: "history_quarters", limit: @limit)
        end
      end

      def reports(scope, as_of:)
        return scope unless @limit
        scope.where("institutional_reports.period_of_report >= ?", earliest(as_of:))
      end

      def holdings(scope, as_of:)
        return scope unless @limit
        scope.where(institutional_report_id: InstitutionalReport.where("period_of_report >= ?", earliest(as_of:)).select(:id))
      end

      def preview(page:, scope:, allowed_scope:, preload: [])
        total = scope.except(:select, :order).count if @limit
        decorate(page.call(allowed_scope, preload:), total_count: total)
      end

      def decorate(result, total_count: nil)
        accessible = result.meta.fetch(:total_count)
        total_count ||= accessible
        CursorPage::Result.new(records: result.records, meta: result.meta.merge(total_count:, accessible_count: accessible,
          truncated: total_count > accessible, feature: "history_quarters", history_quarters: @limit,
          earliest_period: earliest(as_of: Time.iso8601(result.meta.fetch(:as_of)))))
      end
    end
  end
end
