# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedScreen do
  it "validates a typed normalized definition outside the API too" do
    user = create(:user)
    screen = user.saved_screens.create!(name: "Example", entity: "companies",
      filters: [ { "field" => "ticker", "operator" => "eq", "value" => "exmp" } ])
    expect(screen).to have_attributes(window_days: 90, sort: "name")
    expect(screen.filters.sole.fetch("value")).to eq("EXMP")
    screen.filters = [ { "field" => "sql", "operator" => "eq", "value" => "TRUE" } ]
    expect(screen).not_to be_valid
  end

  it "backs case-insensitive per-user name uniqueness with a database index" do
    user = create(:user)
    user.saved_screens.create!(name: "Example", entity: "funds")
    expect do
      described_class.insert_all!([ { user_id: user.id, name: "EXAMPLE", entity: "funds" } ])
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects an invalid window at the database boundary" do
    screen = create(:user).saved_screens.create!(name: "Example", entity: "companies")
    expect { screen.update_columns(window_days: nil) }.to raise_error(ActiveRecord::StatementInvalid, /saved_screen_window/)
  end

  it "rejects JSON objects in the filters column at the database boundary" do
    screen = create(:user).saved_screens.create!(name: "Example", entity: "funds")
    expect { screen.update_columns(filters: {}) }.to raise_error(ActiveRecord::StatementInvalid, /saved_screen_filters/)
  end
end
