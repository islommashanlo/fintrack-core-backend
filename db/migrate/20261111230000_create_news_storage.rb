# frozen_string_literal: true

class CreateNewsStorage < ActiveRecord::Migration[8.0]
  def change
    create_table :news_items do |t|
      t.string :provider, null: false
      t.string :provider_item_id, null: false
      t.string :source, null: false
      t.string :title, null: false
      t.string :url, null: false
      t.datetime :published_at, null: false
      t.datetime :observed_at, null: false
      t.string :kind, null: false
      t.string :suppression_reason
      t.timestamps
    end
    add_index :news_items, %i[provider provider_item_id], unique: true
    add_index :news_items, %i[published_at id]
    add_check_constraint :news_items, "provider ~ '^[a-z][a-z0-9_]{0,39}$' AND char_length(provider_item_id) BETWEEN 1 AND 200",
                         name: "news_items_provider_identity"
    add_check_constraint :news_items, "kind IN ('news', 'press_release', 'other')", name: "news_items_kind"
    add_check_constraint :news_items, "char_length(btrim(title)) BETWEEN 1 AND 500 AND char_length(btrim(source)) BETWEEN 1 AND 200 " \
                                    "AND char_length(url) BETWEEN 1 AND 2048 AND published_at <= observed_at",
                         name: "news_items_metadata"
    add_check_constraint :news_items, "suppression_reason IS NULL OR suppression_reason IN ('restricted_language', 'markup')",
                         name: "news_items_suppression"

    create_table :news_mentions do |t|
      t.references :news_item, null: false, foreign_key: true
      t.references :entity, polymorphic: true, null: false
      t.string :role, null: false
      t.datetime :observed_at, null: false
      t.timestamps
    end
    add_index :news_mentions, %i[news_item_id entity_type entity_id role], unique: true, name: "index_news_mentions_on_identity"
    add_check_constraint :news_mentions,
                         "entity_id > 0 AND ((entity_type = 'Filer' AND role IN ('issuer', 'person')) " \
                         "OR (entity_type = 'InstitutionalFiler' AND role = 'fund'))",
                         name: "news_mentions_entity_role"
  end
end
