# frozen_string_literal: true

module Api
  module V1
    class NotificationsController < ProtectedController
      def index
        values = read_parameters(allowed: %w[unread sort limit cursor])
        raise InvalidParameter, "Invalid unread filter" if values["unread"] && !%w[true false].include?(values["unread"])
        page = CursorPage.new(parameters: values, context: { "resource" => "in_app_notifications", "version" => 4, "user_id" => Current.user.id },
          sorts: { "published_at" => "in_app_notifications.published_at" }, default_sort: "-published_at",
          bounds: { "notifications" => Current.user.in_app_notifications, "filings" => Filing, "reports" => InstitutionalReport, "news_items" => NewsItem, "news_mentions" => NewsMention }, as_of:)
        scope = Current.user.in_app_notifications.visible_at(page.as_of, max_filing_id: page.bound("filings"), max_report_id: page.bound("reports"), max_news_item_id: page.bound("news_items"), max_news_mention_id: page.bound("news_mentions"))
          .where("in_app_notifications.id <= ? AND in_app_notifications.created_at <= ?", page.bound("notifications"), page.as_of)
        scope = scope.where("in_app_notifications.read_at IS #{values['unread'] == 'true' ? '' : 'NOT '}NULL") if values["unread"]
        result = page.call(scope, preload: [ :filing, :news_alert_snapshot, :insider_cluster_snapshot, { insider_transaction: :filing }, { institutional_change_snapshot: [ :primary_filing, :institutional_filer ] }, { alert_rule: :follow } ])
        serializer = InAppNotificationSerializer.new(records: result.records, as_of: page.as_of)
        render json: { data: result.records.map { |record| serializer.render(record) }, meta: result.meta }
      end

      def summary
        read_parameters(allowed: [])
        total, unread = visible.pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE in_app_notifications.read_at IS NULL)"))
        render json: { data: { total_count: total, unread_count: unread, read_count: total - unread, as_of: } }
      end

      def read
        read_parameters(allowed: [], path_keys: [ :id ])
        record = InAppNotificationReads.mark(user: Current.user, id: AlertParameters.id!(params[:id]), as_of:)
        render json: { data: { id: record.id, read_at: record.read_at } }
      end

      def read_all
        read_parameters(allowed: [])
        result = InAppNotificationReads.mark_all(user: Current.user, as_of:)
        render json: { data: result }
      end

      private

      def visible
        Current.user.in_app_notifications.visible_at(as_of)
      end
    end
  end
end
