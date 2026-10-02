# frozen_string_literal: true

# Amendment matching needs a filing's reporting owners even when it reports no
# transactions (holdings-only filings have no insider_transactions rows).
class AddOwnerCiksToFilings < ActiveRecord::Migration[8.0]
  def change
    add_column :filings, :owner_ciks, :string, array: true, null: false, default: []
    add_index :filings, :owner_ciks, using: :gin
  end
end
