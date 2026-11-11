# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Filing email unsubscribe" do
  include ApiAccounts
  let(:user) { create(:user) }

  it "does not mutate preferences on GET and accepts signed one-click POST without cookies or CSRF" do
    preference = consent_email(user)
    token = EmailUnsubscribe.token(user)
    with_api_csrf_protection do
      get email_unsubscribe_path(token:)
      expect(response).to have_http_status(:ok)
      expect(preference.reload).to be_email_enabled
      2.times do
        post email_unsubscribe_path(token:), params: { "List-Unsubscribe" => "One-Click" }
        expect(response).to have_http_status(:ok)
      end
    end
    expect(preference.reload).not_to be_email_enabled
  end

  it "rejects altered tokens and stale tokens after explicit re-opt-in or email changes" do
    consent_email(user)
    token = EmailUnsubscribe.token(user)
    post email_unsubscribe_path(token: "#{token}x"), params: { "List-Unsubscribe" => "One-Click" }
    expect(response).to have_http_status(:not_found)
    EmailUnsubscribe.disable(token)
    NotificationPreferences.update(user:, attributes: { email_enabled: true })
    post email_unsubscribe_path(token:), params: { "List-Unsubscribe" => "One-Click" }
    expect(response).to have_http_status(:not_found)
    expect(user.notification_preference.reload).to be_email_enabled
    token = EmailUnsubscribe.token(user)
    user.update!(email_address: "changed@example.com")
    post email_unsubscribe_path(token:), params: { "List-Unsubscribe" => "One-Click" }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects missing one-click arguments without changing consent" do
    preference = consent_email(user)
    post email_unsubscribe_path(token: EmailUnsubscribe.token(user))
    expect(response).to have_http_status(:bad_request)
    expect(preference.reload).to be_email_enabled
  end
end
