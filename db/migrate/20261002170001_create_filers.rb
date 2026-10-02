# frozen_string_literal: true

class CreateFilers < ActiveRecord::Migration[8.0]
  def change
    create_table :filers do |t|
      t.string :cik, null: false # ten digits, zero-padded, as EDGAR writes it
      t.string :name, null: false
      t.string :filer_type, null: false # insider | issuer (institution arrives with 13F)

      t.timestamps
    end

    add_index :filers, :cik, unique: true
  end
end
