# frozen_string_literal: true

FactoryBot.define do
  sequence(:accession_no) { |n| format("0009999999-26-%06d", n) }
  sequence(:cik) { |n| format("%010d", 9_000_000 + n) }

  factory :filer do
    cik
    name { "Example Filer" }
    filer_type { "insider" }
  end

  factory :filing do
    accession_no
    cik { "0000000123" }
    form_type { "4" }
    filed_on { Date.new(2026, 9, 30) }
    filed_at { Time.utc(2026, 9, 30, 20, 0) }
    accepted_at { filed_at }
    ingested_at { filed_at }
    period_of_report { Date.new(2026, 9, 28) }
    parse_status { "parsed" }
    issuer_cik { "0000000123" }
    issuer_name { "Example Corp" }
    issuer_ticker { "EXMP" }

    trait :pending do
      parse_status { "pending" }
      filed_at { nil }
      period_of_report { nil }
      issuer_cik { nil }
      issuer_name { nil }
      issuer_ticker { nil }
    end
  end

  factory :insider_transaction do
    filing
    accession_no { filing.accession_no }
    issuer_cik { filing.issuer_cik }
    issuer_ticker { filing.issuer_ticker }
    insider_cik { "0000000456" }
    insider_name { "Doe Jane" }
    owner_seq { 1 }
    security_table { "non_derivative" }
    sequence(:txn_seq)
    security_title { "Common Stock" }
    transaction_date { filing.period_of_report }
    transaction_code { "P" }
    shares { 100 }
    price { 10 }
    acquired_disposed { "A" }
    direct_or_indirect { "D" }
  end
end
