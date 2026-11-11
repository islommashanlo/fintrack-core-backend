# frozen_string_literal: true

module Api
  module V1
    class NewsReadScope
      attr_reader :target

      def initialize(page:, target:, user:)
        @page, @target, @user = page, target, user
      end

      def resolved?
        return nil unless target

        model = target.fetch(:role) == "fund" ? InstitutionalFiler : Filer
        scope = model.where(cik: target[:cik])
        scope = scope.where(filer_type: target.fetch(:role) == "issuer" ? "issuer" : "insider") if model == Filer
        scope.exists?
      end

      def mentions
        scope = News::Visibility.mentions(as_of: @page.as_of).where("news_mentions.id <= ?", @page.bound("mentions"))
        if target
          scope.where(role: target.fetch(:role)).where("COALESCE(news_filer.cik, news_fund.cik) = ?", target[:cik])
        else
          scope.where(watchlist_predicate)
        end
      end

      private

      def watchlist_predicate
        bindings = { user_id: @user.id, as_of: @page.as_of, follows: @page.bound("follows") }
        ApplicationRecord.sanitize_sql_array([ <<~SQL, bindings ])
          EXISTS (
            SELECT 1 FROM follows
            WHERE follows.user_id = :user_id AND follows.removed_at IS NULL
              AND follows.id <= :follows AND follows.followed_at <= :as_of
              AND (#{News::Visibility.follow_match(as_of: @page.as_of, max_filing_id: @page.bound("filings"))})
          )
        SQL
      end
    end
  end
end
