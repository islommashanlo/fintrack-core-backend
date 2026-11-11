# frozen_string_literal: true

class AddNewsAlertSources < ActiveRecord::Migration[8.0]
  def up
    create_table :news_alert_snapshots do |t|
      t.references :news_item, null: false, foreign_key: true
      t.references :news_mention, null: false, foreign_key: true, index: { unique: true }
      %i[provider provider_item_id source title url kind entity_type role cik].each { |field| t.string field, null: false }
      t.bigint :entity_id, null: false
      %i[published_at item_observed_at mention_observed_at observed_at].each { |field| t.datetime field, null: false }
      t.timestamps
    end
    add_check_constraint :news_alert_snapshots,
      "kind IN ('news', 'press_release', 'other') AND cik ~ '^[0-9]{10}$' AND entity_id > 0 " \
      "AND ((entity_type = 'Filer' AND role IN ('issuer', 'person')) OR (entity_type = 'InstitutionalFiler' AND role = 'fund'))",
      name: "news_snapshot_identity"
    add_reference :alert_deliveries, :news_item, foreign_key: true
    add_reference :alert_deliveries, :news_alert_snapshot, foreign_key: true
    change_column_null :alert_deliveries, :filing_id, true
    remove_check_constraint :alert_deliveries, name: "alert_delivery_source"
    add_check_constraint :alert_deliveries, <<~SQL.squish, name: "alert_delivery_source"
      (news_item_id IS NULL AND news_alert_snapshot_id IS NULL AND filing_id IS NOT NULL AND (
        (event_type = 'new_filing' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
        OR (event_type = 'insider_transaction' AND insider_transaction_id IS NOT NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
        OR (event_type = 'cluster' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NOT NULL AND institutional_change_snapshot_id IS NULL)
        OR (event_type = '13f_change' AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NOT NULL)
      )) OR (event_type = 'news' AND filing_id IS NULL AND news_item_id IS NOT NULL AND news_alert_snapshot_id IS NOT NULL
        AND insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL)
    SQL
    remove_index :alert_deliveries, name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, %i[alert_rule_id filing_id], unique: true,
      where: "insider_transaction_id IS NULL AND insider_cluster_snapshot_id IS NULL AND institutional_change_snapshot_id IS NULL AND news_item_id IS NULL",
      name: :index_alert_deliveries_on_alert_rule_id_and_filing_id
    add_index :alert_deliveries, %i[alert_rule_id news_item_id], unique: true,
      where: "news_item_id IS NOT NULL", name: :index_alert_deliveries_on_rule_and_news_item
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Review news alert history before removing its source evidence"
  end
end
