# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HTML password recovery" do
  it "normalizes addresses and uses the shared recovery job without exposing whether the account exists" do
    create(:user)
    expect do
      post passwords_path, params: { email_address: " USER@EXAMPLE.COM " }
    end.to have_enqueued_job(SendPasswordResetJob)
    expect(response).to redirect_to(new_session_path)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "consumes tokens once and revokes sessions through the shared reset service" do
    user = create(:user)
    session = user.sessions.create!
    token = user.password_reset_token
    get edit_password_path(token)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Referrer-Policy"]).to eq("no-referrer")
    put password_path(token), params: { password: "replacement123", password_confirmation: "replacement123" }
    expect(response).to redirect_to(new_session_path)
    expect(Session.exists?(session.id)).to be(false)
    expect(user.reload.authenticate("replacement123")).to be_truthy
    put password_path(token), params: { password: "anotherpassword123", password_confirmation: "anotherpassword123" }
    expect(response).to redirect_to(new_password_path)
    expect(user.reload.authenticate("replacement123")).to be_truthy
  end

  it "does not accept missing or mismatched passwords and preserves token validity" do
    user = create(:user)
    token = user.password_reset_token
    put password_path(token), params: {}
    expect(response).to redirect_to(edit_password_path(token))
    expect(User.find_by_password_reset_token(token)).to eq(user)
    put password_path(token), params: { password: "replacement123", password_confirmation: "different" }
    expect(response).to redirect_to(edit_password_path(token))
    expect(User.find_by_password_reset_token(token)).to eq(user)
  end

  it "does not issue an HTML session when credentials change during authentication" do
    user = create(:user, password: "password123")
    allow(User).to receive(:authenticate_by).and_wrap_original do |original, values|
      result = original.call(values)
      User.find(user.id).update!(password: "replacement123")
      result
    end
    post session_path, params: { email_address: user.email_address, password: "password123" }
    expect(response).to redirect_to(new_session_path)
    expect(user.sessions.count).to eq(0)
  end
end
