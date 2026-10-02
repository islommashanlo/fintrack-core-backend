# frozen_string_literal: true

class CreateFilings < ActiveRecord::Migration[8.0]
  def change
    create_table :filings do |t|
      t.string :accession_no, null: false
      t.string :cik, null: false # a CIK the filing is archived under on EDGAR; enough to fetch it
      t.string :form_type, null: false
      t.date :filed_on # filing date as listed by the index or search hit
      t.datetime :filed_at # EDGAR acceptance time; point-in-time logic keys on this
      t.date :period_of_report
      t.string :raw_path # location in the filing archive
      t.string :parse_status, null: false, default: "pending"
      t.datetime :parsed_at
      t.string :source # how we learned of it: efts | daily_index

      # Ownership forms (3/4/5), as reported in the filing
      t.string :issuer_cik
      t.string :issuer_name
      t.string :issuer_ticker
      t.boolean :aff10b5_one
      t.jsonb :footnotes, null: false, default: {}

      # Amendments: both rows stay; the original points at what superseded it
      t.date :date_of_original_submission
      t.string :amends_accession_no
      t.string :superseded_by_accession_no
      t.string :unmatched_reason

      t.timestamps
    end

    add_index :filings, :accession_no, unique: true
    add_index :filings, :filed_at
    add_index :filings, %i[form_type filed_on]
    add_index :filings, :parse_status
    add_index :filings, %i[issuer_cik period_of_report]
    add_check_constraint :filings, "parse_status IN ('pending', 'parsed', 'failed')", name: "filings_parse_status_check"
  end
end
