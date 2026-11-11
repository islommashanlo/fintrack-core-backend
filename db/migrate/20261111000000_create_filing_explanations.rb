# frozen_string_literal: true

class CreateFilingExplanations < ActiveRecord::Migration[8.0]
  def change
    create_table :filing_explanations do |t|
      t.references :filing, null: false, foreign_key: true
      t.string :source_digest, null: false
      t.string :prompt_version, null: false
      t.string :provider_key, null: false
      t.string :model, null: false
      t.string :generation_method, null: false
      t.text :body, null: false
      t.jsonb :coverage, null: false, default: {}
      t.datetime :generated_at, null: false
      t.timestamps

      t.index %i[filing_id source_digest prompt_version provider_key], unique: true,
              name: :index_filing_explanations_on_source_and_provider
      t.check_constraint "generation_method IN ('template', 'provider')", name: :filing_explanation_method
      t.check_constraint "source_digest ~ '^[0-9a-f]{64}$'", name: :filing_explanation_digest
      t.check_constraint "jsonb_typeof(coverage) = 'object'", name: :filing_explanation_coverage
    end
  end
end
