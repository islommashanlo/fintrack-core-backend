# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: 'noreply@fintrack.com'
  layout 'mailer'

  def sendgrid_client
    @sendgrid_client ||= SendGrid::API.new(api_key: ENV.fetch('SENDGRID_API_KEY', 'your_sendgrid_api_key'))
  end
end
