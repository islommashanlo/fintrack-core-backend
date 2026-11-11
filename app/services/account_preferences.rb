# frozen_string_literal: true

class AccountPreferences
  def self.update(user:, attributes:)
    user.with_lock do
      preference = user.user_preference || user.build_user_preference
      preference.update!(attributes)
      preference
    end
  end
end
