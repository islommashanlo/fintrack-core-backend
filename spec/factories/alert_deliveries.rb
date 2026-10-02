# frozen_string_literal: true

FactoryBot.define do
  factory :alert_delivery do
    alert_rule { create(:follow).alert_rule }
    filing
    status { "pending" }
  end
end
