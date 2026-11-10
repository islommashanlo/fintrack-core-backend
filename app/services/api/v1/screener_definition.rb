# frozen_string_literal: true

module Api
  module V1
    class ScreenerDefinition
      COMMON = { "name" => :text, "cik" => :cik, "last_filed_on" => :date }.freeze
      TRANSACTIONS = {
        "purchase_count" => :count, "sale_count" => :count, "open_market_count" => :count,
        "purchase_value" => :decimal, "sale_value" => :decimal, "net_open_market_value" => :decimal,
        "transactions_without_usable_value" => :count
      }.freeze
      FIELDS = {
        "companies" => COMMON.merge(TRANSACTIONS).merge("ticker" => :ticker, "insider_count" => :count).freeze,
        "insiders" => COMMON.merge(TRANSACTIONS).merge("issuer_count" => :count,
          "latest_is_director" => :boolean, "latest_is_officer" => :boolean,
          "latest_is_ten_percent_owner" => :boolean, "latest_is_other" => :boolean).freeze,
        "funds" => COMMON.merge("period_of_report" => :date, "holding_row_count" => :count,
          "position_count" => :count, "portfolio_value_usd" => :decimal, "suspect" => :boolean).freeze
      }.freeze
      OPERATORS = {
        text: %w[eq not_eq contains starts_with in is_null not_null],
        cik: %w[eq not_eq in], ticker: %w[eq not_eq in contains starts_with is_null not_null],
        count: %w[eq not_eq gt gte lt lte between in is_null not_null],
        decimal: %w[eq not_eq gt gte lt lte between in is_null not_null],
        date: %w[eq not_eq gt gte lt lte between in is_null not_null], boolean: %w[eq not_eq]
      }.transform_values(&:freeze).freeze

      def self.sorts(entity)
        FIELDS.fetch(entity).to_h do |field, type|
          [ field, type == :text ? "LOWER(activity.#{field})" : "activity.#{field}" ]
        end.merge("last_filed_at" => "activity.last_filed_at")
      end
    end
  end
end
