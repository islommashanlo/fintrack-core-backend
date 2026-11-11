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
        scope = NewsMention.joins(<<~SQL)
          LEFT JOIN filers news_filer ON news_mentions.entity_type = 'Filer' AND news_filer.id = news_mentions.entity_id
          LEFT JOIN institutional_filers news_fund ON news_mentions.entity_type = 'InstitutionalFiler' AND news_fund.id = news_mentions.entity_id
        SQL
        scope = scope.where("news_mentions.id <= ? AND news_mentions.observed_at <= ?", @page.bound("mentions"), @page.as_of)
          .where(<<~SQL)
            (news_mentions.role = 'fund' AND news_fund.id IS NOT NULL) OR
            (news_mentions.role = 'issuer' AND news_filer.filer_type = 'issuer') OR
            (news_mentions.role = 'person' AND news_filer.filer_type = 'insider')
          SQL
        if target
          scope.where(role: target.fetch(:role)).where("COALESCE(news_filer.cik, news_fund.cik) = ?", target[:cik])
        else
          scope.where(watchlist_predicate)
        end
      end

      private

      def watchlist_predicate
        bindings = { user_id: @user.id, as_of: @page.as_of, follows: @page.bound("follows"), filings: @page.bound("filings") }
        ApplicationRecord.sanitize_sql_array([ <<~SQL, bindings ])
          EXISTS (
            SELECT 1 FROM follows
            WHERE follows.user_id = :user_id AND follows.removed_at IS NULL
              AND follows.id <= :follows AND follows.followed_at <= :as_of
              AND (
                (follows.target_type = 'Insider' AND news_mentions.role = 'person' AND follows.target_key = news_filer.cik) OR
                (follows.target_type = 'InstitutionalFiler' AND news_mentions.role = 'fund' AND follows.target_key = news_fund.cik) OR
                (follows.target_type = 'Ticker' AND news_mentions.role = 'issuer' AND news_filer.cik = (
                  SELECT issuer_cik FROM filings WHERE UPPER(issuer_ticker) = follows.target_key
                    AND form_type IN ('4', '4/A') AND parse_status = 'parsed' AND id <= :filings
                    AND filed_at <= :as_of AND ingested_at <= :as_of AND (parsed_at IS NULL OR parsed_at <= :as_of)
                  ORDER BY filed_at DESC, accession_no DESC LIMIT 1
                ))
              )
          )
        SQL
      end
    end
  end
end
