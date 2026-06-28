# frozen_string_literal: true

class CreateInstitutionalHoldings < ActiveRecord::Migration[7.1]
  def change
    create_table :institutional_holdings do |t|
      t.references :trade_source, null: false, foreign_key: true, index: true
      t.string  :period_of_report, null: false          # e.g. "2024-09-30"
      t.string  :ticker,           null: false
      t.string  :company_name
      t.string  :cusip,            limit: 9
      t.decimal :shares,           precision: 20, scale: 4
      t.decimal :value,            precision: 20, scale: 2  # USD market value
      t.string  :investment_discretion                  # Sole, Shared, None
      t.string  :put_call,         limit: 10            # Put, Call, or NULL
      t.string  :filing_url,       limit: 500
      t.datetime :filing_date

      t.timestamps
    end

    add_index :institutional_holdings, :ticker
    add_index :institutional_holdings, :period_of_report
    add_index :institutional_holdings,
              %i[trade_source_id period_of_report ticker],
              name: 'idx_inst_holdings_source_period_ticker'
  end
end
