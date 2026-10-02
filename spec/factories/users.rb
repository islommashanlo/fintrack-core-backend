# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    email_address { "user@example.com" }
    password { "password" }
  end
end
