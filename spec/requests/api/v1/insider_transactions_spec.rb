# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 insider transactions" do
  around do |example|
    travel_to(Time.utc(2026, 10, 5, 12, 0)) { example.run }
  end

  def rows
    response.parsed_body.fetch("data")
  end

  def meta
    response.parsed_body.fetch("meta")
  end

  it "returns factual classifications, reported values, roles and filing provenance" do
    filing = create(:filing, filed_at: Time.utc(2026, 10, 1, 20),
                    accepted_at: Time.utc(2026, 10, 1, 20), ingested_at: Time.utc(2026, 10, 2, 12))
    purchase = create(:insider_transaction, filing:, shares: BigDecimal("12.5"), price: BigDecimal("20.25"),
                      is_director: true, shares_owned_following: 500)
    sale = create(:insider_transaction, filing:, transaction_code: "S")
    award = create(:insider_transaction, filing:, transaction_code: "A", price: nil)

    get api_v1_insider_transactions_path

    expect(response).to have_http_status(:ok)
    expect(rows.map { |row| row.fetch("id") }).to eq([ award.id, sale.id, purchase.id ])
    expect(rows.last).to include(
      "accession" => filing.accession_no, "sec_url" => filing.sec_url,
      "filed_at" => "2026-10-01T20:00:00.000Z", "accepted_at" => "2026-10-01T20:00:00.000Z",
      "ingested_at" => "2026-10-02T12:00:00.000Z", "data_age_days" => 4,
      "direction" => "purchase", "activity_type" => "open_market", "value" => "253.125",
      "shares" => "12.5", "price" => "20.25", "shares_owned_following" => "500.0",
      "role" => include("is_director" => true),
      "issuer" => { "cik" => filing.issuer_cik, "name" => filing.issuer_name, "ticker" => filing.issuer_ticker }
    )
    expect(rows[1]).to include("direction" => "sale", "activity_type" => "open_market")
    expect(rows.first).to include("direction" => "other", "activity_type" => "administrative", "value" => nil)
    expect(meta).to include("total_count" => 3, "has_more" => false, "next_cursor" => nil,
                            "limit" => 50, "sort" => "-filed_at", "as_of" => "2026-10-05T12:00:00.000000Z")
  end

  it "filters transaction types, including administrative rows without a code" do
    purchase = create(:insider_transaction)
    sale = create(:insider_transaction, transaction_code: "S")
    award = create(:insider_transaction, transaction_code: "A")
    unknown = create(:insider_transaction, transaction_code: nil)

    get api_v1_insider_transactions_path, params: { type: "open_market" }
    expect(rows.pluck("id")).to contain_exactly(purchase.id, sale.id)

    get api_v1_insider_transactions_path, params: { type: "administrative" }
    expect(rows.pluck("id")).to contain_exactly(award.id, unknown.id)
  end

  it "combines code, role, insider, company, direction and security-table filters" do
    purchase = create(:insider_transaction, is_officer: true, officer_title: "CFO")
    create(:insider_transaction, transaction_code: "S", is_officer: true)
    create(:insider_transaction, is_director: true)
    create(:insider_transaction, issuer_ticker: "EXMP.A", is_officer: true)
    create(:insider_transaction, security_table: "derivative", is_officer: true)
    create(:insider_transaction, insider_cik: "0000000789", is_officer: true)

    get api_v1_insider_transactions_path, params: {
      type: "open_market", code: "p,s", direction: "purchase", role: "officer",
      insider_cik: purchase.insider_cik, issuer_cik: purchase.issuer_cik, ticker: "exmp",
      security_table: "non_derivative"
    }

    expect(rows.pluck("id")).to eq([ purchase.id ])
    expect(meta.fetch("total_count")).to eq(1)
  end

  it "filters other directions and all supported insider roles" do
    role_columns = { "director" => :is_director, "officer" => :is_officer,
                     "ten_percent_owner" => :is_ten_percent_owner, "other" => :is_other }
    transactions = role_columns.transform_values { |column| create(:insider_transaction, column => true, transaction_code: "G") }
    create(:insider_transaction, is_director: true)

    transactions.each do |role, transaction|
      get api_v1_insider_transactions_path, params: { role:, direction: "other" }
      expect(rows.pluck("id")).to eq([ transaction.id ])
    end
  end

  it "uses inclusive transaction dates and value bounds, excluding missing and suspect prices from value filters" do
    first = create(:insider_transaction, transaction_date: Date.new(2026, 9, 1), shares: 10, price: 10)
    last = create(:insider_transaction, transaction_date: Date.new(2026, 9, 30), shares: 20, price: 10)
    create(:insider_transaction, transaction_date: Date.new(2026, 8, 31), shares: 10, price: 10)
    create(:insider_transaction, shares: 30, price: 10)
    suspect = create(:insider_transaction, price: 100_000, price_suspect: true, price_suspect_reason: "implausible")
    create(:insider_transaction, price: nil)

    get api_v1_insider_transactions_path, params: { date_from: "2026-09-01", date_to: "2026-09-30", min_value: "100", max_value: "200" }
    expect(rows.pluck("id")).to contain_exactly(first.id, last.id)

    get api_v1_insider_transactions_path
    expect(rows.find { |row| row["id"] == suspect.id }).to include("price" => "100000.0", "value" => nil,
                                                                "price_suspect" => true, "price_suspect_reason" => "implausible")
    expect(suspect.reload.price).to eq(BigDecimal("100000"))
  end

  it "retains every reporting owner and both security tables without implying aggregate trade counts" do
    filing = create(:filing)
    first = create(:insider_transaction, filing:, txn_seq: 1)
    joint = create(:insider_transaction, filing:, txn_seq: 1, owner_seq: 2, insider_cik: "0000000789")
    derivative = create(:insider_transaction, filing:, txn_seq: 1, security_table: "derivative")

    get api_v1_insider_transactions_path
    expect(rows.pluck("id")).to contain_exactly(first.id, joint.id, derivative.id)

    get api_v1_insider_transactions_path, params: { insider_cik: joint.insider_cik }
    expect(rows.pluck("id")).to eq([ joint.id ])
    expect(rows.first.fetch("owner_sequence")).to eq(2)
  end

  it "excludes unparsed, undated, future and non-Form-4 filings" do
    visible = create(:insider_transaction)
    [ { parse_status: "pending" }, { parse_status: "failed" }, { filed_at: nil },
      { filed_at: 1.day.from_now }, { form_type: "13F-HR" } ].each do |attributes|
      create(:insider_transaction, filing: create(:filing, **attributes))
    end

    get api_v1_insider_transactions_path
    expect(rows.pluck("id")).to eq([ visible.id ])
  end

  it "resolves amendment chains in SQL, including equal acceptance timestamps" do
    original = create(:filing, filed_at: Time.utc(2026, 9, 28))
    first = create(:filing, form_type: "4/A", filed_at: Time.utc(2026, 9, 30), amends_accession_no: original.accession_no)
    final = create(:filing, form_type: "4/A", filed_at: first.filed_at, amends_accession_no: original.accession_no)
    create(:insider_transaction, filing: original)
    create(:insider_transaction, filing: first)
    replacement = create(:insider_transaction, filing: final)

    get api_v1_insider_transactions_path
    expect(rows.pluck("id")).to eq([ replacement.id ])
    expect(Filing.where(id: [ original.id, first.id, final.id ]).count).to eq(3)
  end

  it "does not suppress an original for failed or future amendments" do
    original = create(:filing)
    transaction = create(:insider_transaction, filing: original)
    create(:filing, form_type: "4/A", amends_accession_no: original.accession_no,
                    parse_status: "failed", filed_at: 1.day.ago)
    create(:filing, form_type: "4/A", amends_accession_no: original.accession_no, filed_at: 1.day.from_now)

    get api_v1_insider_transactions_path
    expect(rows.pluck("id")).to eq([ transaction.id ])
  end

  %w[filed_at -filed_at transaction_date -transaction_date value -value].each do |sort|
    it "pages through #{sort} ties and nulls without repeating or skipping rows" do
      filing = create(:filing, filed_at: Time.utc(2026, 9, 28))
      a = create(:insider_transaction, filing:, transaction_date: Date.new(2026, 9, 1), shares: 10, price: 10)
      b = create(:insider_transaction, filing:, transaction_date: a.transaction_date, shares: 10, price: 10)
      c = create(:insider_transaction, filing: create(:filing, filed_at: Time.utc(2026, 9, 29)),
                  transaction_date: Date.new(2026, 9, 2), shares: 20, price: 10)
      d = create(:insider_transaction, transaction_date: nil, price: nil)
      e = create(:insider_transaction, transaction_date: nil, price_suspect: true)
      field = sort.delete_prefix("-")
      expected = if field == "filed_at"
        [ a, b, c, d, e ]
      elsif sort.start_with?("-")
        [ c, b, a, e, d ]
      else
        [ a, b, c, d, e ]
      end
      expected.reverse! if sort == "-filed_at"
      ids = []
      cursor = nil
      loop do
        get api_v1_insider_transactions_path, params: { sort:, limit: 1 }.merge(cursor ? { cursor: } : {})
        expect(response).to have_http_status(:ok)
        expect(meta.fetch("total_count")).to eq(5)
        ids.concat(rows.pluck("id"))
        cursor = meta.fetch("next_cursor")
        break unless meta.fetch("has_more")

        expect(ids.length).to be < 5
      end
      expect(ids).to eq(expected.map(&:id))
    end
  end

  it "preserves decimal precision when values become cursor boundaries" do
    first = create(:insider_transaction, shares: BigDecimal("9223372036854775808000.000001"), price: 1)
    second = create(:insider_transaction, shares: BigDecimal("9223372036854775808000.000002"), price: 1)

    get api_v1_insider_transactions_path, params: { sort: "-value", limit: 1 }
    expect(rows.pluck("id")).to eq([ second.id ])
    cursor = meta.fetch("next_cursor")

    get api_v1_insider_transactions_path, params: { sort: "-value", limit: 1, cursor: }
    expect(rows.pluck("id")).to eq([ first.id ])
    expect(rows.first.fetch("value")).to eq("9223372036854775808000.000001")
  end

  it "keeps a cursor snapshot stable when late filings, amendments or owner rows arrive" do
    original = create(:filing)
    oldest = create(:insider_transaction, filing: original)
    newest = create(:insider_transaction)

    get api_v1_insider_transactions_path, params: { limit: 1 }
    expect(rows.pluck("id")).to eq([ newest.id ])
    cursor = meta.fetch("next_cursor")
    create(:insider_transaction, filing: original)
    create(:insider_transaction, filing: create(:filing, filed_at: original.filed_at - 1.day))
    amendment = create(:filing, form_type: "4/A", filed_at: original.filed_at + 1.day,
                      amends_accession_no: original.accession_no)
    create(:insider_transaction, filing: amendment)

    get api_v1_insider_transactions_path, params: { limit: 1, cursor: }
    expect(rows.pluck("id")).to eq([ oldest.id ])
    expect(meta).to include("total_count" => 2, "has_more" => false, "next_cursor" => nil)
  end

  it "rejects altered, expired and mismatched cursors" do
    create_list(:insider_transaction, 2)
    get api_v1_insider_transactions_path, params: { limit: 1 }
    cursor = meta.fetch("next_cursor")

    [ { cursor: "#{cursor}x" }, { cursor:, sort: "filed_at" }, { cursor:, role: "director" } ].each do |parameters|
      get api_v1_insider_transactions_path, params: parameters
      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body.dig("error", "message")).to eq("Invalid cursor parameter")
    end

    travel 25.hours
    get api_v1_insider_transactions_path, params: { cursor: }
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects malformed parameters and SQL fragments with JSON errors" do
    [ { type: "invalid" }, { role: "ceo" }, { direction: "invalid" }, { code: "P,'S" },
      { security_table: "unknown" }, { ticker: "EXMP%" }, { insider_cik: "123" }, { issuer_cik: "123" },
      { min_value: "NaN" }, { max_value: "-1" }, { min_value: "20", max_value: "10" },
      { date_from: "2026-02-30" }, { date_to: "yesterday" }, { date_from: "2026-10-01", date_to: "2026-09-30" },
      { limit: "0" }, { limit: "101" }, { limit: "1.5" }, { sort: "filed_at; DROP TABLE filings" },
      { unexpected: "anything" }, { role: [ "officer" ] }, { code: { value: "P" } }, { type: "" },
      { cursor: "x" * 8193 } ].each do |parameters|
      get api_v1_insider_transactions_path, params: parameters
      expect(response).to have_http_status(:bad_request), parameters.inspect
      expect(response.parsed_body.dig("error", "code")).to eq("INVALID_PARAMETER")
    end
  end

  it "returns an empty page with consistent metadata" do
    get api_v1_insider_transactions_path
    expect(rows).to eq([])
    expect(meta).to include("total_count" => 0, "has_more" => false, "next_cursor" => nil)
  end

  it "preloads filing provenance without a query for every transaction" do
    create_list(:insider_transaction, 5)
    filing_reads = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      filing_reads << payload[:sql] if payload[:sql].match?(/SELECT "filings"\.\*/)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get api_v1_insider_transactions_path
    end

    expect(rows.length).to eq(5)
    expect(filing_reads.length).to eq(1)
  end
end
