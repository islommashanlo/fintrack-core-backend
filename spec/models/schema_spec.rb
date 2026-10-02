# frozen_string_literal: true

require "rails_helper"

# Invariant 2: upserts are keyed on natural keys backed by unique indexes.
RSpec.describe "Natural-key indexes" do
  def unique_index_columns(table)
    ActiveRecord::Base.connection.indexes(table).select(&:unique).map(&:columns)
  end

  it "backs every natural key with a unique index" do
    expect(unique_index_columns(:filers)).to include([ "cik" ])
    expect(unique_index_columns(:filings)).to include([ "accession_no" ])
    expect(unique_index_columns(:insider_transactions))
      .to include(%w[accession_no insider_cik security_table txn_seq])
    expect(unique_index_columns(:parse_failures)).to include([ "accession_no" ])
    expect(unique_index_columns(:backfill_runs)).to include([ "day" ])
  end

  it "rejects a second transaction row with the same natural key" do
    row = create(:insider_transaction, txn_seq: 1)

    expect { create(:insider_transaction, filing: row.filing, txn_seq: 1) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "stores reported numbers without rounding them" do
    row = create(:insider_transaction, shares: BigDecimal("955608.711"), price: BigDecimal("0.123456789012"))

    expect(row.reload.shares).to eq(BigDecimal("955608.711"))
    expect(row.price).to eq(BigDecimal("0.123456789012"))
  end

  it "refuses to delete a filing that has transactions" do
    row = create(:insider_transaction)

    expect { row.filing.destroy }.to raise_error(ActiveRecord::DeleteRestrictionError)
  end
end
