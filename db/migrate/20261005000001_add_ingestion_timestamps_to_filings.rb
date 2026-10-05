# frozen_string_literal: true

class AddIngestionTimestampsToFilings < ActiveRecord::Migration[8.0]
  def up
    add_column :filings, :accepted_at, :datetime
    add_column :filings, :ingested_at, :datetime
    add_index :filings, :accepted_at
    add_index :filings, :ingested_at

    execute <<~SQL
      UPDATE filings
      SET accepted_at = filed_at,
          ingested_at = parsed_at
      WHERE accepted_at IS NULL OR ingested_at IS NULL
    SQL
  end

  def down
    remove_index :filings, :ingested_at
    remove_index :filings, :accepted_at
    remove_column :filings, :ingested_at
    remove_column :filings, :accepted_at
  end
end
