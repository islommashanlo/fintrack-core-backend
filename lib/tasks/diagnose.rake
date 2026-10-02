# frozen_string_literal: true

namespace :diagnose do
  desc "List rows flagged price_suspect, and the highest unflagged prices, for review"
  task prices: :environment do
    columns = {
      "Accession" => "accession_no", "Ticker" => "issuer_ticker", "Insider" => ->(r) { r["insider_name"].to_s.truncate(26) },
      "Code" => "transaction_code", "Shares" => "shares", "Price" => "price", "Shares x price" => "implied_value",
      "Reason" => "price_suspect_reason"
    }
    select = "t.accession_no, t.issuer_ticker, t.insider_name, t.transaction_code, t.shares, t.price, " \
             "t.shares * t.price AS implied_value, t.price_suspect_reason"
    base = "FROM insider_transactions t WHERE t.owner_seq = 1"

    puts "Flagged price_suspect (kept as reported, left out of value sums):"
    puts TextTable.render(
      ApplicationRecord.connection.select_all("SELECT #{select} #{base} AND t.price_suspect ORDER BY t.price DESC NULLS LAST LIMIT 200").to_a, columns
    )
    puts "", "Twenty highest prices that are not flagged:"
    puts TextTable.render(
      ApplicationRecord.connection.select_all("SELECT #{select} #{base} AND NOT t.price_suspect AND t.price IS NOT NULL ORDER BY t.price DESC LIMIT 20").to_a, columns
    )
    puts "", "A flagged row is a filer error if shares x price is implausible for the company, and genuine if the stock really trades that high."
  end

  desc "List unresolved parse failures"
  task failures: :environment do
    rows = ParseFailure.unresolved.order(:last_failed_at).limit(200).map(&:attributes)

    puts TextTable.render(rows, { "Accession" => "accession_no", "Attempts" => "attempts", "Last failed" => "last_failed_at",
                                  "Error" => ->(r) { r["error"].to_s.truncate(110) } })
  end
end
