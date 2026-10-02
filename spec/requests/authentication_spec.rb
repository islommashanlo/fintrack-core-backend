# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Authentication" do
  it "allows a visitor to create an account and reaches the dashboard" do
    expect do
      post signup_path, params: {
        user: { email_address: "new@example.com", password: "password123", password_confirmation: "password123" }
      }
    end.to change(User, :count).by(1)

    expect(response).to redirect_to(root_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("new@example.com")
  end

  it "signs an existing user in and out" do
    user = create(:user, email_address: "reader@example.com", password: "password123")

    post session_path, params: { email_address: user.email_address, password: "password123" }
    expect(response).to redirect_to(root_url)

    delete session_path
    expect(response).to redirect_to(new_session_path)
  end
end
