# frozen_string_literal: true

class AddInstitutionalFieldsToTradeSources < ActiveRecord::Migration[7.1]
  def change
    add_column :trade_sources, :institution_type, :string, limit: 100
    add_column :trade_sources, :aum, :decimal, precision: 20, scale: 2
    add_column :trade_sources, :net_worth_tier, :string, limit: 50
    add_column :trade_sources, :cik, :string, limit: 20

    add_index :trade_sources, :institution_type
    add_index :trade_sources, :net_worth_tier
    add_index :trade_sources, :cik, unique: true, where: 'cik IS NOT NULL'
  end
end
