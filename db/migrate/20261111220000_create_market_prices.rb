# frozen_string_literal: true

class CreateMarketPrices < ActiveRecord::Migration[8.0]
  def change
    create_table :price_series do |t|
      t.references :security, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_symbol, null: false
      t.string :currency, null: false
      t.string :adjustment, null: false
      t.timestamps
    end
    add_index :price_series, %i[security_id provider provider_symbol currency adjustment],
              unique: true, name: "index_price_series_on_identity"
    add_check_constraint :price_series, "currency ~ '^[A-Z]{3}$'", name: "price_series_currency"
    add_check_constraint :price_series, "adjustment IN ('unadjusted', 'split_adjusted')", name: "price_series_adjustment"
    add_check_constraint :price_series, "provider ~ '^[a-z][a-z0-9_]{0,39}$' AND char_length(btrim(provider_symbol)) BETWEEN 1 AND 100",
                         name: "price_series_provider_identity"

    create_table :prices_daily do |t|
      t.references :price_series, null: false, foreign_key: true, index: false
      t.date :session_date, null: false
      t.decimal :open, null: false
      t.decimal :high, null: false
      t.decimal :low, null: false
      t.decimal :close, null: false
      t.decimal :volume, null: false
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_index :prices_daily, %i[price_series_id session_date], unique: true
    add_check_constraint :prices_daily,
                         "open > 0 AND low > 0 AND close > 0 AND high >= open AND high >= close AND low <= open AND low <= close " \
                         "AND volume >= 0 AND volume = trunc(volume) " \
                         "AND open NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) " \
                         "AND high NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) " \
                         "AND low NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) " \
                         "AND close NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric) " \
                         "AND volume NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)",
                         name: "prices_daily_ohlcv"
  end
end
