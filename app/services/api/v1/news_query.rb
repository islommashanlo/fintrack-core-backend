# frozen_string_literal: true

module Api
  module V1
    class NewsQuery
      PARAMETERS = %w[from to kind source provider sort limit cursor].freeze

      def initialize(parameters:, target: nil, user: nil, as_of: Time.current)
        raise ArgumentError, "Expected one news target or watchlist user" unless target.nil? != user.nil?

        @values, @target, @user = parameters, target, user
        validate_filters!
        providers = News::Publication.providers
        @providers, @language_pattern = providers, News::Publication.language_pattern
        context = { "resource" => "news", "role" => target&.fetch(:role), "cik" => target&.fetch(:cik),
                    "user_id" => user&.id, "public_providers" => providers, "language_policy" => @language_pattern }
        context["memberships"] = membership_digest(as_of) if user
        @page = CursorPage.new(parameters:, context:, sorts: {
          "published_at" => "news_items.published_at", "observed_at" => "news_items.observed_at"
        }, default_sort: "-published_at", bounds: {
          "items" => NewsItem, "mentions" => NewsMention, "follows" => Follow, "filings" => Filing
        }, as_of:)
        @to = date_filter("to") || @page.as_of.utc.to_date
        @from = date_filter("from") || @to - 29
        if @from > @to || (@to - @from).to_i >= 366 || @to > @page.as_of.utc.to_date
          raise InvalidParameter, "Invalid news date range"
        end
      end

      def call
        read_scope = NewsReadScope.new(page: @page, target: @target, user: @user)
        mentions = read_scope.mentions
        scope = News::Visibility.items(as_of: @page.as_of).where(id: mentions.select(:news_item_id))
          .where("news_items.id <= ? AND news_items.observed_at <= ? AND published_at >= ? AND published_at < ? AND published_at <= ?",
                 @page.bound("items"), @page.as_of, utc_midnight(@from), utc_midnight(@to + 1), @page.as_of)
        %w[kind source provider].each { |field| scope = scope.where(field => @values[field]) if @values[field] }
        result = @page.call(scope)
        serializer = NewsItemSerializer.new(records: result.records, mentions:)
        resolved = read_scope.resolved?
        status = @providers.empty? ? "publication_disabled" : (resolved == false ? "identity_unresolved" : "local_cache")
        { data: result.records.map { |record| serializer.render(record) }, meta: result.meta.merge(
          status:, from: @from, to: @to, entity_resolved: resolved,
          scope: @user ? "watchlist" : @target.fetch(:role), complete: nil, fetched: false,
          mention_scope: "matching_feed_entities", disclaimer: FilingsIntel::DISCLAIMER
        ) }
      end

      private

      def validate_filters!
        if @values["kind"] && !NewsItem::KINDS.include?(@values["kind"])
          raise InvalidParameter, "Invalid kind parameter"
        end
        if @values["source"] && (@values["source"].length > 200 || @values["source"].match?(/[[:cntrl:]]/))
          raise InvalidParameter, "Invalid source parameter"
        end
        if @values["provider"] && !@values["provider"].match?(/\A[a-z][a-z0-9_]{0,39}\z/)
          raise InvalidParameter, "Invalid provider parameter"
        end
      end

      def date_filter(key)
        return unless @values[key]

        date = Date.iso8601(@values[key])
        raise Date::Error unless date.iso8601 == @values[key]

        date
      rescue Date::Error
        raise InvalidParameter, "Invalid #{key} parameter"
      end

      def utc_midnight(date)
        Time.utc(date.year, date.month, date.day)
      end

      def membership_digest(as_of)
        @user.follows.current.where("followed_at <= ?", as_of).pick(Arel.sql(
          "md5(COALESCE(string_agg((to_jsonb(follows) - 'updated_at' - 'created_at')::text, '' ORDER BY follows.id), ''))"
        ))
      end
    end
  end
end
