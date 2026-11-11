# frozen_string_literal: true

FactoryBot.define do
  factory :security do
    sequence(:figi) { |n| "TESTFIGI#{n}" }
    ticker { "EXAMPLE" }
    name { "Example Issuer" }
    source { "openfigi" }
  end
end
