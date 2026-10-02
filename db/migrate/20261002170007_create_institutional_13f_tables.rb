# frozen_string_literal: true

class CreateInstitutional13fTables < ActiveRecord::Migration[8.0]
  def change
    create_table :institutional_filers do |t|
      t.string :cik, null: false
      t.string :name, null: false

      t.timestamps
    end

    add_index :institutional_filers, :cik, unique: true

    create_table :institutional_reports do |t|
      t.references :filing, null: false, foreign_key: true, index: false
      t.references :institutional_filer, null: false, foreign_key: true, index: false
      t.date :period_of_report, null: false
      t.datetime :filed_at
      t.string :submission_type, null: false
      t.string :report_type, null: false
      t.string :amendment_type
      t.integer :amendment_number
      t.integer :other_included_managers_count
      t.integer :table_entry_total
      t.decimal :table_value_total
      t.string :cover_value_unit
      t.string :cover_raw_path
      t.string :information_raw_path
      t.string :status, null: false, default: "pending"
      t.boolean :suspect, null: false, default: false
      t.string :suspect_reason

      t.timestamps
    end

    add_index :institutional_reports, :filing_id, unique: true
    add_index :institutional_reports, %i[institutional_filer_id period_of_report],
              name: "index_institutional_reports_on_filer_and_period"
    add_index :institutional_reports, %i[institutional_filer_id filed_at],
              name: "index_institutional_reports_on_filer_and_filed_at"
    add_check_constraint :institutional_reports,
                         "status IN ('pending', 'parsed', 'failed', 'skipped')",
                         name: "institutional_reports_status_check"

    create_table :institutional_report_managers do |t|
      t.references :institutional_report, null: false, foreign_key: true, index: false
      t.integer :sequence_no, null: false
      t.string :cik
      t.string :name
      t.string :form13f_file_number
      t.string :crd_number
      t.string :sec_file_number

      t.timestamps
    end

    add_index :institutional_report_managers, %i[institutional_report_id sequence_no],
              unique: true, name: "index_13f_report_managers_on_report_and_sequence"
    add_check_constraint :institutional_report_managers, "sequence_no > 0",
                         name: "institutional_report_managers_sequence_positive"

    create_table :institutional_holdings do |t|
      t.references :institutional_report, null: false, foreign_key: true, index: false
      t.integer :row_seq, null: false
      t.string :cusip
      t.string :name_of_issuer, null: false
      t.string :title_of_class, null: false
      t.decimal :value_reported, null: false
      t.string :value_unit, null: false
      t.decimal :value_usd
      t.decimal :shares, null: false
      t.string :share_type, null: false
      t.string :put_call
      t.string :investment_discretion
      t.string :other_manager
      t.decimal :voting_sole
      t.decimal :voting_shared
      t.decimal :voting_none
      t.string :figi
      t.boolean :suspect, null: false, default: false
      t.string :suspect_reason

      t.timestamps
    end

    add_index :institutional_holdings, %i[institutional_report_id row_seq],
              unique: true, name: "index_13f_holdings_on_report_and_row"
    add_index :institutional_holdings, :cusip
    add_check_constraint :institutional_holdings, "row_seq > 0",
                         name: "institutional_holdings_row_sequence_positive"
  end
end
