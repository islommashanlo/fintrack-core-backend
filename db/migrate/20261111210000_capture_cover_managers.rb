# frozen_string_literal: true

class CaptureCoverManagers < ActiveRecord::Migration[8.0]
  def change
    add_column :institutional_reports, :other_managers_recorded, :boolean, null: false, default: false

    create_table :institutional_report_other_managers do |t|
      t.references :institutional_report, null: false, foreign_key: true, index: false
      t.integer :sequence_no, null: false
      t.string :cik
      t.string :name
      t.string :form13f_file_number
      t.string :crd_number
      t.string :sec_file_number
      t.timestamps
    end
    add_index :institutional_report_other_managers, %i[institutional_report_id sequence_no],
              unique: true, name: "index_13f_other_managers_on_report_and_sequence"
    add_check_constraint :institutional_report_other_managers, "sequence_no > 0",
                         name: "institutional_other_managers_positive_sequence"
  end
end
