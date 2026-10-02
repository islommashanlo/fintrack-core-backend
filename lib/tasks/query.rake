# frozen_string_literal: true

namespace :query do
  desc "Open-market purchases filed in the last DAYS days (default 7)"
  task :recent_purchases, %i[days limit] => :environment do |_, args|
    rows = InsiderSignals.new.recent_purchases(days: (args[:days] || 7).to_i, limit: (args[:limit] || 50).to_i)

    puts TextTable.render(rows, {
      "Filed (UTC)" => "filed_at", "Ticker" => "issuer_ticker", "Issuer" => ->(r) { r["issuer_name"].to_s.truncate(30) },
      "Insider" => ->(r) { r["insider_name"].to_s.truncate(28) }, "Title" => ->(r) { r["officer_title"].to_s.truncate(20).presence },
      "Trade date" => "transaction_date", "Shares" => "shares", "Price" => "price", "Value" => "value",
      "Suspect" => "price_suspect", "Accession" => "accession_no"
    })
    puts "", FilingsIntel::DISCLAIMER
  end

  desc "Issuers with at least MIN distinct insiders filing purchases in the last DAYS days (default 30, 2)"
  task :cluster_buys, %i[days min_insiders limit] => :environment do |_, args|
    rows = InsiderSignals.new.cluster_buys(
      days: (args[:days] || 30).to_i, min_insiders: (args[:min_insiders] || 2).to_i, limit: (args[:limit] || 50).to_i
    )

    puts TextTable.render(rows, {
      "Ticker" => "issuer_ticker", "Issuer" => ->(r) { r["issuer_name"].to_s.truncate(34) }, "Insiders" => "insiders",
      "Purchases" => "purchases", "Shares" => "shares", "Value" => "value",
      "No usable price" => "purchases_without_usable_price", "First filed" => "first_filed_at", "Last filed" => "last_filed_at"
    })
    puts "", FilingsIntel::DISCLAIMER
  end

  desc "Insiders ranked by the value of purchases filed in the last DAYS days (default 90)"
  task :top_insiders, %i[days limit] => :environment do |_, args|
    rows = InsiderSignals.new.top_insiders(days: (args[:days] || 90).to_i, limit: (args[:limit] || 25).to_i)

    puts TextTable.render(rows, {
      "Insider" => ->(r) { r["insider_name"].to_s.truncate(34) }, "CIK" => "insider_cik", "Purchases" => "purchases",
      "Issuers" => "issuers", "Value" => "value", "No usable price" => "purchases_without_usable_price",
      "Last filed" => "last_filed_at"
    })
    puts "", FilingsIntel::DISCLAIMER
  end
end
