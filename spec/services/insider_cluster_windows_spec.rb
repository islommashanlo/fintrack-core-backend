# frozen_string_literal: true

require "rails_helper"

RSpec.describe InsiderClusterWindows do
  include ClusterAlertHelpers
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }

  [ "ACME:from", "ACME:to", "ACME:min_insiders", "ACME' OR TRUE -- :missing", 'ACME\\1:missing' ].each do |ticker|
    it "preserves the quoted source filter #{ticker.inspect}" do
      included = cluster_trades
      included.each { |trade| trade.update!(issuer_ticker: ticker) }
      cluster_trades
      source = described_class.source(as_of: Time.current).where(issuer_ticker: ticker)
      sql = described_class.sql(source:, from: 1.day.ago, to: Time.current)
      rows = Api::V1::CursorPage.sql_rows(sql)

      expect(rows.size).to eq(1)
      expect(rows.sole.fetch("transaction_ids")).to eq(included.map(&:id))
      expect(rows.sole).to include("insider_count" => 3, "transaction_count" => 3)
    end
  end
end
