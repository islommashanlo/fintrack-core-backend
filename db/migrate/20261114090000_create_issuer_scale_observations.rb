# frozen_string_literal: true

class CreateIssuerScaleObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :issuer_scale_observations do |t|
      t.string :issuer_cik, null: false
      t.string :source, null: false
      t.string :source_record_id, null: false
      t.string :source_revision, null: false
      t.decimal :market_cap, null: false
      t.string :currency, null: false
      t.string :measurement_basis, null: false
      t.datetime :effective_at, null: false
      t.datetime :observed_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :issuer_scale_observations, %i[issuer_cik source source_record_id source_revision],
      unique: true, name: "issuer_scale_source_identity"
    add_index :issuer_scale_observations, %i[issuer_cik effective_at observed_at created_at], name: "issuer_scale_knowledge_time"
    add_check_constraint :issuer_scale_observations, "issuer_cik ~ '^[0-9]{10}$'", name: "issuer_scale_cik"
    add_check_constraint :issuer_scale_observations, "source ~ '^[a-z][a-z0-9_]{0,39}$'", name: "issuer_scale_source"
    add_check_constraint :issuer_scale_observations,
      "source_record_id ~ '[^[:space:]]' AND char_length(source_record_id) <= 200 AND source_revision ~ '[^[:space:]]' AND char_length(source_revision) <= 100 AND measurement_basis ~ '[^[:space:]]' AND char_length(measurement_basis) <= 100",
      name: "issuer_scale_metadata"
    add_check_constraint :issuer_scale_observations,
      "market_cap >= 0 AND market_cap::text NOT IN ('NaN', 'Infinity', '-Infinity') AND currency ~ '^[A-Z]{3}$'",
      name: "issuer_scale_amount"
    add_check_constraint :issuer_scale_observations, "isfinite(effective_at) AND isfinite(observed_at) AND isfinite(created_at) AND effective_at <= observed_at AND observed_at <= created_at",
      name: "issuer_scale_times"
  end
end
