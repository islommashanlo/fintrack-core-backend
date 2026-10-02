# frozen_string_literal: true

require "rails_helper"

RSpec.describe InsiderSignals do
  let(:now) { Time.utc(2026, 10, 1, 12, 0) }
  let(:signals) { described_class.new(as_of: now) }

  def filing(issuer: "0000000111", filed_at: now - 1.day, owners: [ "0000000901" ], **attributes)
    create(:filing, issuer_cik: issuer, issuer_name: "Issuer #{issuer.to_i}", issuer_ticker: "T#{issuer.to_i}",
                    filed_at:, filed_on: filed_at.to_date, owner_ciks: owners, **attributes)
  end

  def purchase(filing, insider: filing.owner_ciks.first, shares: 100, price: 10, **attributes)
    create(:insider_transaction, filing:, insider_cik: insider, insider_name: "Insider #{insider.to_i}",
                                 shares:, price:, **attributes)
  end

  describe "#recent_purchases" do
    it "lists open-market purchases with their value, newest filing first" do
      older = purchase(filing(filed_at: now - 3.days), shares: 10, price: 5)
      newer = purchase(filing(filed_at: now - 1.day), shares: 32, price: BigDecimal("19.13"))

      rows = signals.recent_purchases(days: 7)

      expect(rows.map { |r| r["accession_no"] }).to eq([ newer.accession_no, older.accession_no ])
      expect(rows.first).to include("shares" => 32, "price" => BigDecimal("19.13"), "value" => BigDecimal("612.16"),
                                    "insider_name" => "Insider 901", "issuer_ticker" => "T111")
    end

    it "only counts code P in the non-derivative table" do
      f = filing
      purchase(f, transaction_code: "S")
      purchase(f, transaction_code: "A")
      purchase(f, transaction_code: nil)
      purchase(f, security_table: "derivative")
      kept = purchase(f)

      expect(signals.recent_purchases.map { |r| r["shares"] }).to eq([ kept.shares ])
    end

    it "keys the window on when the filing was accepted, not on the trade date" do
      purchase(filing(filed_at: now - 2.days), transaction_date: Date.new(2026, 1, 5))  # old trade, filed now
      purchase(filing(filed_at: now - 30.days), transaction_date: now.to_date)          # filed long ago
      purchase(filing(filed_at: now + 1.hour))                                          # not yet filed

      rows = signals.recent_purchases(days: 7)

      expect(rows.size).to eq(1)
      expect(rows.first["transaction_date"]).to eq(Date.new(2026, 1, 5))
    end

    it "leaves the value empty for a suspect or missing price but still lists the purchase" do
      f = filing
      purchase(f, shares: 100, price: 61_216, price_suspect: true, price_suspect_reason: "over_50k_per_share")
      purchase(f, shares: 100, price: nil)

      rows = signals.recent_purchases

      expect(rows.size).to eq(2)
      expect(rows.map { |r| r["value"] }).to eq([ nil, nil ])
      expect(rows.map { |r| r["price_suspect"] }).to contain_exactly(true, false)
    end

    it "counts a joint filing once, under the first-listed owner" do
      joint = filing(owners: %w[0000000901 0000000902 0000000903])
      joint.owner_ciks.each_with_index do |cik, index|
        purchase(joint, insider: cik, owner_seq: index + 1, txn_seq: 1, shares: 500, price: 2)
      end

      rows = signals.recent_purchases

      expect(rows.size).to eq(1)
      expect(rows.first).to include("insider_cik" => "0000000901", "reporting_owners" => 3, "value" => 1000)
    end
  end

  describe "amendments" do
    let(:original) { filing(filed_at: now - 10.days) }
    let(:amendment) do
      filing(filed_at: now - 2.days, form_type: "4/A", amends_accession_no: original.accession_no)
    end

    before do
      purchase(original, shares: 7899, price: 1)
      purchase(amendment, shares: 7946, price: 1)
      original.update!(superseded_by_accession_no: amendment.accession_no)
    end

    it "uses the amendment in place of the original" do
      expect(signals.recent_purchases(days: 30).map { |r| r["shares"] }).to eq([ 7946 ])
    end

    it "still sees the original when asked as of a time before the amendment was filed" do
      as_of_then = described_class.new(as_of: now - 5.days)

      expect(as_of_then.recent_purchases(days: 30).map { |r| r["shares"] }).to eq([ 7899 ])
    end

    it "keeps only the newest of several amendments" do
      second = filing(filed_at: now - 1.day, form_type: "4/A", amends_accession_no: original.accession_no)
      purchase(second, shares: 8000, price: 1)

      expect(signals.recent_purchases(days: 30).map { |r| r["shares"] }).to eq([ 8000 ])
      expect(described_class.new(as_of: now - 36.hours).recent_purchases(days: 30).map { |r| r["shares"] }).to eq([ 7946 ])
    end
  end

  describe "#cluster_buys" do
    it "finds issuers with several distinct buyers and totals them in SQL" do
      purchase(filing(owners: [ "0000000901" ]), shares: 100, price: 10)
      purchase(filing(owners: [ "0000000902" ], filed_at: now - 2.days), shares: 50, price: 20)
      purchase(filing(owners: [ "0000000902" ], filed_at: now - 3.days), shares: 10, price: nil)
      purchase(filing(issuer: "0000000222", owners: [ "0000000903" ]), shares: 999, price: 1) # a single buyer

      rows = signals.cluster_buys(days: 30, min_insiders: 2)

      expect(rows.size).to eq(1)
      expect(rows.first).to include(
        "issuer_cik" => "0000000111", "issuer_ticker" => "T111", "insiders" => 2, "purchases" => 3,
        "shares" => 160, "value" => 2000, "purchases_without_usable_price" => 1
      )
      expect(rows.first["last_filed_at"]).to eq(now - 1.day)
    end

    it "does not treat joint filers on one filing as a cluster" do
      joint = filing(owners: %w[0000000901 0000000902])
      joint.owner_ciks.each_with_index { |cik, i| purchase(joint, insider: cik, owner_seq: i + 1, txn_seq: 1) }

      expect(signals.cluster_buys(days: 30, min_insiders: 2)).to be_empty
    end

    it "keeps suspect prices out of the value" do
      purchase(filing(owners: [ "0000000901" ]), shares: 100, price: 10)
      purchase(filing(owners: [ "0000000902" ]), shares: 100, price: 90_000, price_suspect: true)

      expect(signals.cluster_buys.first).to include("insiders" => 2, "value" => 1000, "purchases_without_usable_price" => 1)
    end
  end

  describe "#top_insiders" do
    it "ranks insiders by the value of purchases filed in the window" do
      purchase(filing(owners: [ "0000000901" ]), shares: 100, price: 10)
      purchase(filing(issuer: "0000000222", owners: [ "0000000901" ]), shares: 100, price: 5)
      purchase(filing(owners: [ "0000000902" ]), shares: 1000, price: 3)
      purchase(filing(owners: [ "0000000903" ], filed_at: now - 200.days), shares: 1, price: 1_000)

      rows = signals.top_insiders(days: 90)

      expect(rows.map { |r| [ r["insider_cik"], r["value"], r["purchases"], r["issuers"] ] }).to eq(
        [ [ "0000000902", 3000, 1, 1 ], [ "0000000901", 1500, 2, 2 ] ]
      )
    end
  end

  it "runs the real fixtures end to end" do
    %i[simple_purchase weighted_average_purchase multi_transaction joint_filers planned_sales gift].each { |n| ingest_form4(n) }

    rows = described_class.new(as_of: Time.utc(2026, 10, 2)).recent_purchases(days: 7)

    expect(rows.map { |r| [ r["issuer_ticker"], r["shares"], r["value"] ] }).to contain_exactly(
      [ "ASGI", 32, BigDecimal("612.16") ],
      [ "FLNA", 93_091, BigDecimal("78196.44") ],
      [ "ADRX", 61_516, BigDecimal("1045772") ],
      [ "NONE", BigDecimal("955608.711"), BigDecimal("22380356.01162") ]
    )
  end
end
