# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserPreference do
  it "enforces one record per user in the database" do
    user = create(:user)
    preference = user.create_user_preference!
    expect do
      described_class.insert_all!([ { user_id: user.id, theme: "dark", dashboard_layout: "focus" } ])
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(preference.theme).to eq("system")
  end

  it "rejects unsupported stored themes even if model validation is bypassed" do
    preference = create(:user).create_user_preference!
    expect { preference.update_columns(theme: "unsupported") }.to raise_error(ActiveRecord::StatementInvalid, /user_preference_theme/)
  end
end
