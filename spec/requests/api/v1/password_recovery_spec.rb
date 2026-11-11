# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 password recovery" do
  include ApiAccounts
  around { |example| with_api_csrf_protection { example.run } }

  def reset_password(token, **values)
    post api_v1_password_reset_path,
      params: { token:, password: "replacement123", password_confirmation: "replacement123", **values },
      headers: api_headers, as: :json
  end

  it "queues an opaque request for both known and unknown accounts with identical responses" do
    user = create(:user)
    api_csrf
    responses = []
    [ "  USER@EXAMPLE.COM ", "missing@example.com" ].each do |email|
      expect do
        post api_v1_password_forgot_path, params: { email: }, headers: api_headers, as: :json
      end.to have_enqueued_job(SendPasswordResetJob).on_queue("default")
      expect(response).to have_http_status(:accepted)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      responses << response.parsed_body
    end
    expect(responses.uniq.size).to eq(1)
    expect(responses.first.to_json).not_to include(user.email_address, "token", user.password_digest)
    arguments = enqueued_jobs.select { |job| job[:job] == SendPasswordResetJob }.map { |job| job[:args].sole }
    expect(arguments).to all(be_a(String))
    expect(arguments.join).not_to include(user.email_address, "password_reset", user.password_reset_token)
    expect(SendPasswordResetJob.log_arguments).to be(false)
  end

  it "resets a password, revokes all target sessions, and requires a fresh sign-in" do
    user = create(:user, password: "password123")
    other = create(:user, email_address: "other@example.com", password: "password123")
    other_session = other.sessions.create!
    api_login(user)
    user.sessions.create!
    original_token = @api_csrf
    token = user.password_reset_token
    reset_password(token)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").keys).to contain_exactly("message", "csrf_token")
    expect(response.parsed_body.dig("data", "csrf_token")).not_to eq(original_token)
    expect(response.body).not_to include(token, user.email_address)
    expect(user.reload.authenticate("replacement123")).to be_truthy
    expect(user.sessions.count).to eq(0)
    expect(Session.exists?(other_session.id)).to be(true)
    get api_v1_me_path
    expect(response).to have_http_status(:unauthorized)
    api_csrf
    reset_password(token)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq("INVALID_RESET_TOKEN")
    api_login(user, password: "replacement123")
    expect(response).to have_http_status(:ok)
  end

  it "rejects expired, tampered and deleted-account tokens with the same public error" do
    user = create(:user)
    api_csrf
    token = user.password_reset_token
    errors = []
    travel 16.minutes do
      reset_password(token)
      expect(response).to have_http_status(:bad_request)
      errors << response.parsed_body
    end
    reset_password("tampered")
    errors << response.parsed_body
    user.destroy!
    reset_password(token)
    errors << response.parsed_body
    expect(errors.uniq.size).to eq(1)
    expect(errors.first.dig("error", "code")).to eq("INVALID_RESET_TOKEN")
  end

  it "invalidates reset links after either an email or password change" do
    user = create(:user, password: "password123")
    api_login(user)
    token = user.password_reset_token
    patch api_v1_me_path, params: { email: "changed@example.com", current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:ok)
    @api_csrf = response.parsed_body.dig("data", "csrf_token")
    reset_password(token)
    expect(response).to have_http_status(:bad_request)
    token = user.reload.password_reset_token
    user.update!(password: "direct-change123")
    reset_password(token)
    expect(response).to have_http_status(:bad_request)
  end

  it "preserves sessions, credentials and reset-token validity when password validation fails" do
    user = create(:user, password: "password123")
    session = user.sessions.create!
    token = user.password_reset_token
    api_csrf
    [ { password: "short", password_confirmation: "short" }, { password_confirmation: "different" },
      { password: "x" * 73, password_confirmation: "x" * 73 } ].each do |values|
      reset_password(token, **values)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("VALIDATION_FAILED")
    end
    expect(user.reload.authenticate("password123")).to be_truthy
    expect(Session.exists?(session.id)).to be(true)
    reset_password(token)
    expect(response).to have_http_status(:ok)
  end

  it "requires valid flat input and rejects account, link-target and credential overrides" do
    api_csrf
    [ {}, { email: [] }, { email: "invalid" }, { email: "x" * 255 },
      { email: "reader@example.com", redirect_url: "https://untrusted.example" } ].each do |values|
      post api_v1_password_forgot_path, params: values, headers: api_headers, as: :json
      expect(response).to have_http_status(:bad_request)
    end
    expect(enqueued_jobs.select { |job| job[:job] == SendPasswordResetJob }).to be_empty
    [ { token: "x" }, { token: [], password: "replacement123", password_confirmation: "replacement123" },
      { token: "x" * 2049, password: "replacement123", password_confirmation: "replacement123" },
      { token: "x", password: "replacement123", password_confirmation: "replacement123", user_id: 1 } ].each do |values|
      post api_v1_password_reset_path, params: values, headers: api_headers, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "requires CSRF protection for both recovery mutations and rejects foreign origins" do
    user = create(:user)
    api_csrf
    post api_v1_password_forgot_path, params: { email: user.email_address }, as: :json
    expect(response).to have_http_status(:forbidden)
    post api_v1_password_reset_path, params: { token: user.password_reset_token, password: "replacement123", password_confirmation: "replacement123" }, as: :json
    expect(response).to have_http_status(:forbidden)
    post api_v1_password_forgot_path, params: { email: user.email_address }, headers: api_headers.merge("Origin" => "https://untrusted.example"), as: :json
    expect(response).to have_http_status(:forbidden)
    expect(enqueued_jobs.select { |job| job[:job] == SendPasswordResetJob }).to be_empty
  end

  it "shares per-address throttling across HTML and API requests and different IPs" do
    user = create(:user)
    api_csrf
    3.times do |i|
      post api_v1_password_forgot_path, params: { email: user.email_address.upcase }, headers: api_headers, as: :json,
        env: { "REMOTE_ADDR" => "192.0.2.#{i + 1}" }
      expect(response).to have_http_status(:accepted)
    end
    post passwords_path, params: { email_address: user.email_address }
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"].to_i).to be_between(1, 900)
  end

  it "throttles reset attempts and recovery requests independently by IP" do
    api_csrf
    10.times do |i|
      post api_v1_password_forgot_path, params: { email: "missing#{i}@example.com" }, headers: api_headers, as: :json
      expect(response).to have_http_status(:accepted)
    end
    post api_v1_password_forgot_path, params: { email: "another@example.com" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:too_many_requests)
    10.times { reset_password("invalid") }
    reset_password("invalid")
    expect(response).to have_http_status(:too_many_requests)
  end

  it "returns a generic temporary error when mail cannot be queued" do
    api_csrf
    allow(SendPasswordResetJob).to receive(:perform_later).and_return(false)
    post api_v1_password_forgot_path, params: { email: "missing@example.com" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body.dig("error", "code")).to eq("TEMPORARILY_UNAVAILABLE")
    expect(response.headers["Retry-After"]).to eq("60")
  end

  it "rechecks credentials under the user lock if a reset races with sign-in" do
    user = create(:user, password: "password123")
    allow(User).to receive(:authenticate_by).and_wrap_original do |original, **values|
      result = original.call(**values)
      User.find(user.id).update!(password: "replacement123")
      result
    end
    api_csrf
    post api_v1_auth_login_path, params: { email: user.email_address, password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(user.sessions.count).to eq(0)
  end

  it "does not complete an old-address sign-in when the account email changes concurrently" do
    user = create(:user, password: "password123")
    allow(User).to receive(:authenticate_by).and_wrap_original do |original, **values|
      result = original.call(**values)
      User.find(user.id).update!(email_address: "changed@example.com")
      result
    end
    api_csrf
    post api_v1_auth_login_path, params: { email: user.email_address, password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(user.sessions.count).to eq(0)
  end
end
