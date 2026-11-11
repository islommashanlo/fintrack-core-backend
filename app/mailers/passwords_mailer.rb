# frozen_string_literal: true

class PasswordsMailer < ApplicationMailer
  def reset(user, token: user.password_reset_token, target: "html")
    @user = user
    origin = Middleware::ApiCors.origin if target == "frontend"
    @reset_url = if origin
      "#{origin}/reset-password#token=#{ERB::Util.url_encode(token)}"
    else
      edit_password_url(token)
    end
    mail subject: "Reset your password", to: user.email_address
  end
end
