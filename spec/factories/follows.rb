# frozen_string_literal: true

FactoryBot.define do
  factory :follow do
    user
    target_type { "Ticker" }
    target_key { "ACME" }
  end
end
