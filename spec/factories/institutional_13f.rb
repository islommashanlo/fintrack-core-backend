# frozen_string_literal: true

FactoryBot.define do
  factory :institutional_filer do
    sequence(:cik) { |n| format("%010d", 8_000_000 + n) }
    name { "Example Institutional Filer" }
  end

  factory :institutional_report do
    filing { create(:filing, form_type: "13F-HR", cik: institutional_filer.cik) }
    institutional_filer
    period_of_report { Date.new(2026, 3, 31) }
    filed_at { Time.utc(2026, 5, 15, 20, 0) }
    submission_type { "13F-HR" }
    report_type { "13F HOLDINGS REPORT" }
    status { "parsed" }
    table_entry_total { 1 }
    table_value_total { BigDecimal("100") }
    cover_value_unit { "whole_dollars" }
  end

  factory :institutional_report_manager do
    institutional_report
    sequence(:sequence_no)
    name { "Example Included Manager" }
  end

  factory :institutional_holding do
    institutional_report
    sequence(:row_seq)
    cusip { "037833100" }
    name_of_issuer { "APPLE INC" }
    title_of_class { "COM" }
    value_reported { BigDecimal("100") }
    value_unit { "whole_dollars" }
    value_usd { BigDecimal("100") }
    shares { BigDecimal("10") }
    share_type { "SH" }
  end
end
