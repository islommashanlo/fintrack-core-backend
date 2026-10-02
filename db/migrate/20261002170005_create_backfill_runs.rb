# frozen_string_literal: true

class CreateBackfillRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :backfill_runs do |t|
      t.date :day, null: false
      t.string :status, null: false, default: "pending"
      t.integer :filings_found, null: false, default: 0
      t.integer :filings_new, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error

      t.timestamps
    end

    add_index :backfill_runs, :day, unique: true
    add_check_constraint :backfill_runs, "status IN ('pending', 'running', 'done', 'no_index', 'failed')",
                         name: "backfill_runs_status_check"
  end
end
