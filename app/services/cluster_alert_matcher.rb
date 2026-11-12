# frozen_string_literal: true

class ClusterAlertMatcher
  SNAPSHOT_FIELDS = %w[event_key issuer_cik issuer_name issuer_ticker transaction_code window_start window_end
    insider_count transaction_count total_value known_value_subtotal transactions_without_usable_price
    transaction_ids insider_ciks filing_ids primary_filing_id insiders].freeze

  def self.call(filing, as_of: Time.current, channel: "email")
    raise ArgumentError, "Unsupported channel" unless AlertRule::CHANNELS.include?(channel)
    return [] unless filing.form_type.in?(Filing::FORM4_TYPES) && filing.filed_at && filing.filed_at <= as_of
    return [] unless AlertRule.active.where(event_type: "cluster", channel:).exists?
    new(filing:, as_of:, channel:).call
  end

  def initialize(filing:, as_of:, channel:)
    @filing, @as_of, @channel = filing, as_of, channel
    @max_filing = Filing.maximum(:id) || 0
    @max_transaction = InsiderTransaction.maximum(:id) || 0
  end

  def call
    matches = Api::V1::CursorPage.sql_rows(matching_sql)
    return [] if matches.empty?
    # DO NOTHING resolves identical windows matched by multiple rules in SQL.
    InsiderClusterSnapshot.insert_all(matches.map do |row|
      row.slice(*SNAPSHOT_FIELDS).merge("window_days" => ActivityMethodology.window_days,
        "definition_minimum_insiders" => ActivityMethodology.minimum_insiders, "observed_at" => @as_of,
        "max_filing_id" => @max_filing, "max_transaction_id" => @max_transaction)
    end, unique_by: :index_insider_cluster_snapshots_on_event_key)
    ids = InsiderClusterSnapshot.where(event_key: matches.map { |row| row.fetch("event_key") }).pluck(:event_key, :id).to_h
    matches.map { |row| row.merge("insider_cluster_snapshot_id" => ids.fetch(row.fetch("event_key")), "filing_id" => row.fetch("primary_filing_id")) }
  end

  private

  def matching_sql
    from = @filing.filed_at
    to = [ from + ActivityMethodology.window_days.days, @as_of + 1.second ].min
    source = InsiderClusterWindows.source(as_of: @as_of, max_filing_id: @max_filing, max_transaction_id: @max_transaction)
      .where(issuer_cik: InsiderTransaction.where(filing_id: @filing.id).select(:issuer_cik))
      .where("filings.filed_at > ?", from - ActivityMethodology.window_days.days)
    windows = InsiderClusterWindows.sql(source:, from:, to:)
    ApplicationRecord.sanitize_sql([ <<~SQL, filing_id: @filing.id, filed_at: from, channel: @channel ])
      WITH windows AS (#{windows})
      SELECT rules.id, settings.frequency, settings.revision AS rule_revision, windows.*
      FROM windows INNER JOIN follows ON (
        (follows.target_type = 'Ticker' AND follows.target_key = UPPER(windows.issuer_ticker))
        OR (follows.target_type = 'Insider' AND EXISTS (
          SELECT 1 FROM insider_transactions canonical INNER JOIN insider_transactions owners
            ON owners.filing_id = canonical.filing_id AND owners.security_table = canonical.security_table AND owners.txn_seq = canonical.txn_seq
          WHERE canonical.id = ANY(windows.transaction_ids) AND owners.id <= #{@max_transaction} AND owners.insider_cik = follows.target_key
        ))
      )
      INNER JOIN alert_rules rules ON rules.follow_id = follows.id
      INNER JOIN alert_rule_settings settings ON settings.alert_rule_id = rules.id
      WHERE rules.active AND rules.event_type = 'cluster' AND rules.channel = :channel
        AND follows.removed_at IS NULL AND settings.archived_at IS NULL
        AND :filed_at >= follows.followed_at AND :filed_at >= settings.enabled_at
        AND windows.filing_ids @> ARRAY[:filing_id]::bigint[]
        AND windows.insider_count >= COALESCE((settings.conditions->>'min_insiders')::integer, #{ActivityMethodology.minimum_insiders})
        AND (settings.conditions->>'direction' IS NULL OR settings.conditions->>'direction' =
          CASE windows.transaction_code WHEN 'P' THEN 'purchase' ELSE 'sale' END)
        AND (settings.conditions->>'min_value' IS NULL OR windows.total_value >= (settings.conditions->>'min_value')::numeric)
    SQL
  end
end
