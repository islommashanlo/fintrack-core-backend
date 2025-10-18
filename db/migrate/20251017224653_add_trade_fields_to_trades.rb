# frozen_string_literal: true

class AddTradeFieldsToTrades < ActiveRecord::Migration[7.1]
  def change
    add_column :trades, :filing_date, :date
    add_column :trades, :trade_date, :date
    add_column :trades, :asset_name, :string
    add_column :trades, :ticker, :string
    add_column :trades, :amount, :decimal, precision: 15, scale: 2
    add_column :trades, :transaction_type, :string
    add_column :trades, :disclosure_url, :string
    add_column :trades, :trade_source_id, :integer

    # Add indexes for performance
    add_index :trades, :filing_date
    add_index :trades, :trade_date
    add_index :trades, :ticker
    add_index :trades, :transaction_type
    add_index :trades, :trade_source_id

    # Add foreign key constraint
    add_foreign_key :trades, :trade_sources, column: :trade_source_id

    # Remove the old trader_id column if it exists
    remove_column :trades, :trader_id, :integer if column_exists?(:trades, :trader_id)
  end
end
