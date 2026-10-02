# frozen_string_literal: true

class CreateInsiderTransactions < ActiveRecord::Migration[8.0]
  def change
    # One row per reporting owner per transaction line, exactly as reported.
    # Numeric columns have no precision or scale so Postgres never rounds a reported value.
    create_table :insider_transactions do |t|
      t.references :filing, null: false, foreign_key: true
      t.string :accession_no, null: false
      t.string :insider_cik, null: false
      t.string :insider_name
      t.integer :owner_seq, null: false # position of this owner in the filing; 1 is the first listed
      t.string :issuer_cik, null: false
      t.string :issuer_ticker

      t.string :security_table, null: false # non_derivative | derivative
      t.integer :txn_seq, null: false # position of the transaction within its table
      t.string :security_title
      t.date :transaction_date
      t.date :deemed_execution_date
      t.string :transaction_code
      t.string :transaction_form_type
      t.boolean :equity_swap_involved
      t.string :transaction_timeliness
      t.decimal :shares
      t.decimal :price
      t.string :acquired_disposed
      t.decimal :shares_owned_following
      t.string :direct_or_indirect
      t.string :nature_of_ownership

      # Derivative table only
      t.decimal :conversion_or_exercise_price
      t.date :exercise_date
      t.date :expiration_date
      t.string :underlying_security_title
      t.decimal :underlying_security_shares

      t.boolean :is_director, null: false, default: false
      t.boolean :is_officer, null: false, default: false
      t.boolean :is_ten_percent_owner, null: false, default: false
      t.boolean :is_other, null: false, default: false
      t.string :officer_title

      # Flags, never corrections: the reported price stays in `price`
      t.boolean :price_suspect, null: false, default: false
      t.string :price_suspect_reason
      t.string :footnote_ids, array: true, null: false, default: []

      t.timestamps
    end

    add_index :insider_transactions, %i[accession_no insider_cik security_table txn_seq],
              unique: true, name: "index_insider_transactions_on_natural_key"
    add_index :insider_transactions, %i[issuer_cik transaction_date]
    add_index :insider_transactions, %i[insider_cik transaction_date]
    add_index :insider_transactions, :transaction_code
    add_check_constraint :insider_transactions, "security_table IN ('non_derivative', 'derivative')",
                         name: "insider_transactions_security_table_check"
  end
end
