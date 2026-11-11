# frozen_string_literal: true

require "rails_helper"

RSpec.describe SendPasswordResetJob do
  include ApiAccounts

  def payload_for(user)
    PasswordRecovery.request(email: user.email_address, ip_address: "192.0.2.1")
    enqueued_jobs.find { |job| job[:job] == described_class }.fetch(:args).sole
  end

  it "sends the original request token to a trusted frontend fragment URL without using the request host" do
    user = create(:user)
    with_frontend_origin("https://app.example.com") do
      payload = payload_for(user)
      expect do
        travel 5.minutes do
          described_class.perform_now(payload)
        end
      end.to change { ActionMailer::Base.deliveries.size }.by(1)
      email = ActionMailer::Base.deliveries.last
      url = email.text_part.body.decoded.lines.find { |line| line.start_with?("https://app.example.com/") }.strip
      parsed = URI.parse(url)
      expect(parsed.path).to eq("/reset-password")
      expect(parsed.query).to be_nil
      delivered_token = URI.decode_www_form(parsed.fragment).to_h.fetch("token")
      expect(delivered_token).to eq(PasswordRecovery.payload(payload).fetch("token"))
      expect(User.find_by_password_reset_token(delivered_token)).to eq(user)
      travel 16.minutes do
        expect(User.find_by_password_reset_token(delivered_token)).to be_nil
      end
      expect(email.to).to eq([ user.email_address ])
      expect(email.html_part.body.decoded).to include("https://app.example.com/reset-password#token=")
      expect(email.subject).to eq("Reset your password")
    end
  end

  it "uses the existing HTML reset page when no separate frontend origin is configured" do
    user = create(:user)
    with_frontend_origin(nil) do
      described_class.perform_now(payload_for(user))
      expect(ActionMailer::Base.deliveries.last.text_part.body.decoded).to include("http://example.com/passwords/")
    end
  end

  it "does not deliver unknown, tampered, expired or credential-changed requests" do
    user = create(:user)
    payload = payload_for(user)
    expect { described_class.perform_now("tampered") }.not_to change { ActionMailer::Base.deliveries.size }
    travel 16.minutes do
      expect { described_class.perform_now(payload) }.not_to change { ActionMailer::Base.deliveries.size }
    end
    user.update!(email_address: "changed@example.com")
    expect { described_class.perform_now(payload) }.not_to change { ActionMailer::Base.deliveries.size }
    PasswordRecovery.request(email: "missing@example.com", ip_address: "192.0.2.1")
    unknown = enqueued_jobs.select { |job| job[:job] == described_class }.last.fetch(:args).sole
    expect { described_class.perform_now(unknown) }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "does not refresh the token lifetime when delivery was delayed" do
    user = create(:user)
    payload = payload_for(user)
    travel 14.minutes do
      described_class.perform_now(payload)
    end
    decoded = PasswordRecovery.payload(payload)
    travel 16.minutes do
      expect(User.find_by_password_reset_token(decoded.fetch("token"))).to be_nil
    end
  end
end
