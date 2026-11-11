# frozen_string_literal: true

class SendPasswordResetJob < ApplicationJob
  queue_as :default
  self.log_arguments = false

  def perform(encrypted_payload)
    payload = PasswordRecovery.payload(encrypted_payload)
    return unless payload&.fetch("token", nil)

    user = User.find_by_password_reset_token(payload.fetch("token"))
    return unless user && user.id == payload.fetch("user_id")

    PasswordsMailer.reset(user, token: payload.fetch("token"), target: payload.fetch("target")).deliver_now
  end
end
