# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Reviewed SQL boundaries" do
  let(:payload) { "x' OR TRUE --" }
  let(:history) { Api::V1::HistoryWindow.new(limit: nil, user_id: nil) }

  it "treats a filing's external ticker as a literal in follow matching" do
    filing = build(:filing, id: -1, issuer_ticker: payload)
    predicate = FilingFollowMatch.sql(filing)
    matched = ApplicationRecord.connection.select_value(<<~SQL)
      SELECT EXISTS (
        SELECT 1 FROM (VALUES ('Ticker', 'SAFE')) AS follows(target_type, target_key)
        WHERE #{predicate}
      )
    SQL
    expect(matched).to be(false)
    expect(predicate).to include("x'' OR TRUE --")
  end

  it "does not broaden archive selection from hostile ID text" do
    create(:filing, raw_path: "fixture.xml")
    expect(ArchiveInventory.new(filing_ids: [ payload ]).documents).to eq([])
  end

  it "rejects external SQL identifiers at news and watchlist boundaries" do
    expect { NewsAlertMatcher.matches(as_of: Time.current, scope: payload) }.to raise_error(ArgumentError)
    expect { NewsAlertMatcher.matches(as_of: Time.current, channel: payload) }.to raise_error(ArgumentError)
    expect { WatchlistFilingMembership.pending_sql(channel: payload) }.to raise_error(KeyError)
    expect { NewsAlertValidity.watchlist_sources(channel: payload, as_of: Time.current) }.to raise_error(KeyError)
    expect { News::Visibility.follow_match(as_of: Time.current, max_filing_id: payload) }.to raise_error(ArgumentError)
  end

  it "binds a hostile directory search instead of returning unrelated funds" do
    create(:institutional_filer, name: "Ordinary fund")
    result = Api::V1::FundDirectoryQuery.new(parameters: { "q" => payload }, history:, as_of: Time.current).call
    expect(result.records).to eq([])
    expect { Api::V1::FundDirectoryQuery.new(parameters: { "min_position_count" => payload }, history:, as_of: Time.current) }
      .to raise_error(Api::V1::InvalidParameter)
  end

  it "rejects a sort expression instead of executing it" do
    expect do
      Api::V1::CursorPage.new(parameters: { "sort" => payload }, context: {},
        sorts: { "name" => "filers.name" }, default_sort: "name")
    end.to raise_error(Api::V1::InvalidParameter)
  end

  it "quotes even signed continuation values as literals" do
    create(:filer, name: "Ordinary issuer")
    options = { context: { "resource" => "security-boundary" }, sorts: { "name" => "filers.name" }, default_sort: "name" }
    page = Api::V1::CursorPage.new(parameters: {}, **options)
    cursor = page.send(:encode, 0, payload)
    continued = Api::V1::CursorPage.new(parameters: { "cursor" => cursor }, **options)
    result = continued.call(Filer.all)
    # Ordinary issuer sorts before the literal x..., so an OR TRUE escape would broaden this page.
    expect(result.records).to eq([])
    sql = continued.send(:after_cursor, Filer.all, "filers.name", "filers").to_sql
    expect(sql).to include("x'' OR TRUE --")
  end

  it "preserves equality semantics when compiling hostile screener text" do
    filter = { "field" => "name", "operator" => "eq", "value" => payload }
    predicate = Api::V1::ScreenerCompiler.call(entity: "companies", filters: [ filter ])
    matched = ApplicationRecord.connection.select_value(<<~SQL)
      SELECT EXISTS (SELECT 1 FROM (VALUES ('Ordinary issuer')) AS activity(name) WHERE #{predicate})
    SQL
    expect(matched).to be(false)
  end
end
