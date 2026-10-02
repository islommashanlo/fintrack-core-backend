# frozen_string_literal: true

# HTTP basic credentials for operator-only endpoints (Sidekiq Web, /ops/metrics).
# With OPS_USERNAME or OPS_PASSWORD unset, nobody gets in.
module OpsAuth
  module_function

  def valid?(username, password)
    expected_user = ENV["OPS_USERNAME"].to_s
    expected_password = ENV["OPS_PASSWORD"].to_s
    return false if expected_user.empty? || expected_password.empty?

    # Compare both values so a wrong username does not answer faster than a wrong password.
    user_ok = ActiveSupport::SecurityUtils.secure_compare(username.to_s, expected_user)
    password_ok = ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_password)
    user_ok && password_ok
  end
end
