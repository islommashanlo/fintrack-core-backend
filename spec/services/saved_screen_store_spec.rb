# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedScreenStore do
  it "enforces the plan at the write boundary as well as the controller" do
    user = create(:user)
    screen = user.saved_screens.create!(name: "Example", entity: "companies", window_days: 90)
    expect do
      described_class.create(user:, attributes: { name: "New", definition: { "entity" => "funds" } })
    end.to raise_error(PlanCatalog::Required)
    expect { described_class.update(user:, id: screen.id, attributes: { name: "Renamed" }) }.to raise_error(PlanCatalog::Required)
    expect { described_class.destroy(user:, id: screen.id) }.to raise_error(PlanCatalog::Required)
    expect(screen.reload.name).to eq("Example")
  end
end
