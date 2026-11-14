# frozen_string_literal: true

class CreateIssuerSecurityEvidences < ActiveRecord::Migration[8.1]
  def change
    create_table :issuer_security_evidences do |t|
      t.references :security, null: false, foreign_key: true
      t.string :issuer_cik, null: false
      t.string :security_figi, null: false
      t.string :cusip
      t.string :ticker
      t.string :source, null: false
      t.string :source_record_id, null: false
      t.string :source_revision, null: false
      t.datetime :effective_from, null: false
      t.datetime :effective_to
      t.datetime :observed_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :issuer_security_evidences, %i[issuer_cik security_id source source_record_id source_revision],
      unique: true, name: "issuer_security_evidence_identity"
    add_index :issuer_security_evidences, %i[issuer_cik effective_from observed_at], name: "issuer_security_evidence_time"
    add_index :issuer_security_evidences, %i[cusip effective_from observed_at], name: "issuer_security_evidence_cusip"
    add_check_constraint :issuer_security_evidences, "issuer_cik ~ '^[0-9]{10}$' AND source ~ '^[a-z][a-z0-9_]{0,39}$'",
      name: "issuer_security_evidence_source"
    add_check_constraint :issuer_security_evidences,
      "security_figi ~ '[^[:space:]]' AND char_length(security_figi) <= 64 AND source_record_id ~ '[^[:space:]]' AND char_length(source_record_id) <= 200 AND source_revision ~ '[^[:space:]]' AND char_length(source_revision) <= 100",
      name: "issuer_security_evidence_metadata"
    add_check_constraint :issuer_security_evidences,
      "(cusip IS NULL OR cusip ~ '^[0-9A-Z]{9}$') AND (ticker IS NULL OR (ticker ~ '[^[:space:]]' AND char_length(ticker) <= 40))",
      name: "issuer_security_evidence_aliases"
    add_check_constraint :issuer_security_evidences,
      "isfinite(effective_from) AND (effective_to IS NULL OR (isfinite(effective_to) AND effective_to > effective_from)) AND isfinite(observed_at) AND isfinite(created_at) AND observed_at <= created_at",
      name: "issuer_security_evidence_times"
  end
end
