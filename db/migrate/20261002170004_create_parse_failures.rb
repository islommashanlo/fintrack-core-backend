# frozen_string_literal: true

class CreateParseFailures < ActiveRecord::Migration[8.0]
  def change
    create_table :parse_failures do |t|
      t.string :accession_no, null: false
      t.text :error, null: false # "ErrorClass: message"
      t.integer :attempts, null: false, default: 0
      t.datetime :last_failed_at
      t.datetime :resolved_at # set when a later run parses the filing; the row is kept

      t.timestamps
    end

    add_index :parse_failures, :accession_no, unique: true
  end
end
