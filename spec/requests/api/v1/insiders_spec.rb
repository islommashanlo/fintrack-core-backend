# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 insider profiles" do
  include OpenapiResponses
  let(:cik) { "0000000456" }
  around { |example| travel_to(Time.utc(2026, 11, 10, 12)) { example.run } }

  def data
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  def owner_filing(**attributes)
    create(:filing, owner_ciks: [ cik ], filed_at: 1.day.ago, **attributes)
  end

  it "finds an administrative co-owner and returns factual identity, provenance and zero open-market counts" do
    filing = owner_filing
    create(:filer, cik:, name: "First Stored Name")
    create(:insider_transaction, filing:, insider_cik: cik, owner_seq: 2, insider_name: "Jane Example",
           transaction_code: "A", price: nil)

    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")

    expect(response).to have_http_status(:ok)
    expect(data).to include("cik" => cik, "name" => "Jane Example")
    expect(data.fetch("latest_filing")).to include("accession" => filing.accession_no,
      "sec_url" => filing.sec_url, "data_age_days" => 1, "filed_at" => filing.filed_at.as_json,
      "accepted_at" => filing.accepted_at.as_json, "ingested_at" => filing.ingested_at.as_json)
    expect(data.fetch("summaries").pluck("window_days")).to eq([ 30, 90, 365 ])
    expect(data.fetch("summaries")).to all(include("purchase_count" => 0, "sale_count" => 0,
      "purchase_value" => nil, "sale_value" => nil, "net_open_market_value" => nil, "counts_by_code" => { "A" => 1 }))
  end

  it "finds an owner with no transaction rows using stored owner CIKs and the first-seen name" do
    create(:filer, cik:, name: "Jane Example")
    filing = owner_filing

    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    expect(data).to include("cik" => cik, "name" => "Jane Example")
    expect(data.dig("latest_filing", "accession")).to eq(filing.accession_no)
    expect(data.fetch("summaries")).to all(include("purchase_count" => 0, "counts_by_code" => {}))

    get transactions_api_v1_insider_path(cik)
    expect(data).to eq([])
    expect(meta.fetch("total_count")).to eq(0)
    get companies_api_v1_insider_path(cik)
    expect(data.first).to include("cik" => filing.issuer_cik, "accession" => filing.accession_no,
      "role" => { "is_director" => nil, "is_officer" => nil, "is_ten_percent_owner" => nil, "is_other" => nil, "officer_title" => nil })
  end

  it "returns null rather than inventing a name when only an owner CIK is stored" do
    owner_filing
    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    expect(data).to include("cik" => cik, "name" => nil)
  end

  it "includes derivative-only owners in identity and transactions without counting derivatives in summaries" do
    filing = owner_filing
    transaction = create(:insider_transaction, filing:, insider_cik: cik, security_table: "derivative", transaction_code: "M")
    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    expect(response).to have_http_status(:ok)
    expect(data.fetch("summaries")).to all(include("counts_by_code" => {}, "issuer_count" => 0))
    get transactions_api_v1_insider_path(cik)
    expect(data.pluck("id")).to eq([ transaction.id ])
  end

  it "computes 30/90/365-day aggregates by acceptance time for this insider including co-owner rows" do
    recent = owner_filing
    create(:insider_transaction, filing: recent, insider_cik: cik, owner_seq: 2, shares: 10, price: 20)
    create(:insider_transaction, filing: recent, insider_cik: "0000000789", owner_seq: 1, shares: 10, price: 20)
    create(:insider_transaction, filing: recent, insider_cik: cik, transaction_code: "S", shares: 5, price: 10)
    create(:insider_transaction, filing: owner_filing(filed_at: 60.days.ago), insider_cik: cik, shares: 10, price: 10)
    create(:insider_transaction, filing: owner_filing(filed_at: 200.days.ago), insider_cik: cik, shares: 20, price: 10)
    create(:insider_transaction, filing: owner_filing(filed_at: 366.days.ago), insider_cik: cik, shares: 99, price: 10)
    create(:insider_transaction, filing: recent, insider_cik: cik, transaction_code: "G", price: nil)
    create(:insider_transaction, filing: recent, insider_cik: cik, transaction_code: nil, price: nil)

    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    summaries = data.fetch("summaries")
    expect(summaries[0]).to include("purchase_count" => 1, "sale_count" => 1, "purchase_value" => "200.0",
      "sale_value" => "50.0", "net_open_market_value" => "150.0", "counts_by_code" => { "P" => 1, "S" => 1, "G" => 1, "unknown" => 1 })
    expect(summaries[1]).to include("purchase_count" => 2, "net_open_market_value" => "250.0")
    expect(summaries[2]).to include("purchase_count" => 3, "net_open_market_value" => "450.0")
  end

  it "flags incomplete open-market values without calculating a misleading net total or altering raw prices" do
    filing = owner_filing
    suspect = create(:insider_transaction, filing:, insider_cik: cik, price: 100_000, price_suspect: true)
    create(:insider_transaction, filing:, insider_cik: cik, transaction_code: "S", price: nil)
    create(:insider_transaction, filing:, insider_cik: cik, shares: 10, price: 20)
    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    expect(data.fetch("summaries")).to all(include("purchase_count" => 2, "sale_count" => 1,
      "purchase_value" => "200.0", "transactions_without_usable_price" => 2, "net_open_market_value" => nil))
    expect(suspect.reload.price).to eq(100_000.to_d)
  end

  it "resolves amendments for transactions and summaries and retains identity through historical disclosures" do
    original = owner_filing(filed_at: 2.days.ago)
    create(:insider_transaction, filing: original, insider_cik: cik, shares: 999)
    amendment = owner_filing(form_type: "4/A", amends_accession_no: original.accession_no)
    corrected = create(:insider_transaction, filing: amendment, insider_cik: cik, shares: 20)
    create(:insider_transaction, filing: owner_filing(form_type: "4/A", parse_status: "failed",
      amends_accession_no: original.accession_no, filed_at: 1.hour.ago), insider_cik: cik)
    create(:insider_transaction, filing: owner_filing(form_type: "4/A", filed_at: 1.day.from_now,
      amends_accession_no: original.accession_no), insider_cik: cik)

    get transactions_api_v1_insider_path(cik)
    expect(data.pluck("id")).to eq([ corrected.id ])
    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    expect(data.fetch("summaries")).to all(include("purchase_count" => 1, "purchase_value" => "200.0"))
  end

  it "does not expose people known only through failed, future, undated or non-Form-4 filings" do
    [ { parse_status: "failed" }, { parse_status: "pending" }, { filed_at: 1.day.from_now },
      { filed_at: nil }, { form_type: "13F-HR" } ].each do |attributes|
      create(:insider_transaction, filing: owner_filing(**attributes), insider_cik: cik)
    end
    create(:filer, cik:, name: "Jane Example")
    get api_v1_insider_path(cik)
    expect_documented_response(path: "/insiders/{cik}")
    expect(response).to have_http_status(:not_found)
  end

  it "scopes transaction filters and cursors to the requested insider" do
    filing = owner_filing
    first = create(:insider_transaction, filing:, insider_cik: cik, is_director: true)
    second = create(:insider_transaction, filing:, insider_cik: cik, is_director: true)
    create(:insider_transaction, filing:, insider_cik: cik, is_officer: true)
    other_cik = "0000000789"
    create(:insider_transaction, filing:, insider_cik: other_cik, is_director: true)
    get transactions_api_v1_insider_path(cik), params: { role: "director", limit: 1 }
    expect(data.pluck("id")).to eq([ second.id ])
    cursor = meta.fetch("next_cursor")
    get transactions_api_v1_insider_path(cik), params: { role: "director", limit: 1, cursor: }
    expect(data.pluck("id")).to eq([ first.id ])
    get transactions_api_v1_insider_path(other_cik), params: { role: "director", cursor: }
    expect(response).to have_http_status(:bad_request)
    get transactions_api_v1_insider_path(cik), params: { insider_cik: other_cik }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns one historical company per issuer CIK with latest reported role and filing provenance" do
    old = owner_filing(filed_at: 2.days.ago)
    create(:insider_transaction, filing: old, insider_cik: cik, is_director: true)
    latest = owner_filing(issuer_name: "Renamed Example", issuer_ticker: "NEW")
    create(:insider_transaction, filing: latest, insider_cik: cik, is_officer: true, officer_title: "CFO", transaction_code: "A")
    create(:insider_transaction, filing: latest, insider_cik: "0000000789", is_director: true)

    get companies_api_v1_insider_path(cik)
    expect(meta.fetch("total_count")).to eq(1)
    expect(data.first).to include("cik" => latest.issuer_cik, "name" => "Renamed Example", "ticker" => "NEW",
      "accession" => latest.accession_no, "sec_url" => latest.sec_url, "role" => include("is_officer" => true, "officer_title" => "CFO", "is_director" => false))
    get companies_api_v1_insider_path(cik), params: { role: "director" }
    expect(data).to eq([])
    get companies_api_v1_insider_path(cik), params: { role: "officer", ticker: "new" }
    expect(data.pluck("cik")).to eq([ latest.issuer_cik ])
  end

  %w[filed_at -filed_at name -name ticker -ticker cik -cik].each do |sort|
    it "paginates company #{sort} ties and nulls with a stable snapshot" do
      first = owner_filing(issuer_cik: "0000000123", issuer_name: "Example", issuer_ticker: "EXMP")
      second = owner_filing(issuer_cik: "0000000124", issuer_name: "Example", issuer_ticker: "EXMP")
      third = owner_filing(issuer_cik: "0000000125", issuer_name: nil, issuer_ticker: nil, filed_at: 2.days.ago)
      expected = if sort.delete_prefix("-") == "filed_at"
        sort.start_with?("-") ? [ second, first, third ] : [ third, first, second ]
      elsif sort.delete_prefix("-") == "cik"
        sort.start_with?("-") ? [ third, second, first ] : [ first, second, third ]
      else
        sort.start_with?("-") ? [ second, first, third ] : [ first, second, third ]
      end
      get companies_api_v1_insider_path(cik), params: { sort:, limit: 1 }
      found = [ data.first.fetch("cik") ]
      cursor = meta.fetch("next_cursor")
      owner_filing(issuer_cik: "0000000126")
      create(:insider_transaction, filing: first, insider_cik: cik, is_director: true)
      owner_filing(issuer_cik: second.issuer_cik, issuer_ticker: "CHANGED", filed_at: 1.hour.ago)
      2.times do
        get companies_api_v1_insider_path(cik), params: { sort:, limit: 1, cursor: }
        expect(response).to have_http_status(:ok)
        found.concat(data.pluck("cik"))
        expect(meta.fetch("total_count")).to eq(3)
        cursor = meta.fetch("next_cursor")
      end
      expect(found).to eq(expected.map(&:issuer_cik))
      expect(meta.fetch("has_more")).to be(false)
    end
  end

  it "rejects invalid filters, malformed identities, tampered, expired and cross-owner company cursors" do
    owner_filing
    owner_filing(issuer_cik: "0000000124")
    get companies_api_v1_insider_path(cik), params: { limit: 1 }
    cursor = meta.fetch("next_cursor")
    [ { role: "ceo" }, { ticker: "EXMP%" }, { role: [ "director" ] }, { sort: "filed_at; SELECT 1" },
      { limit: "101" }, { unrelated: "value" }, { cursor: "#{cursor}x" } ].each do |values|
      get companies_api_v1_insider_path(cik), params: values
      expect(response).to have_http_status(:bad_request), values.inspect
    end
    owner_filing(owner_ciks: [ "0000000789" ])
    get companies_api_v1_insider_path("0000000789"), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
    get api_v1_insider_path("456")
    expect_documented_response(path: "/insiders/{cik}")
    expect(response).to have_http_status(:bad_request)
    get api_v1_insider_path("0000000001")
    expect_documented_response(path: "/insiders/{cik}")
    expect(response).to have_http_status(:not_found)
    travel 25.hours
    get companies_api_v1_insider_path(cik), params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "keeps the existing global transactions route distinct from an insider CIK" do
    get api_v1_insider_transactions_path
    expect(response).to have_http_status(:ok)
    expect(data).to eq([])
  end
end
