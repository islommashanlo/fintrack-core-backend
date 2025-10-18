# frozen_string_literal: true

class NotificationService
  def self.send_trade_alerts(trade)
    # Find all active alert preferences that match this trade
    matching_preferences = AlertPreference.active.joins(:user).includes(:user)

    matching_preferences.find_each do |preference|
      next unless preference.matches_trade?(trade)

      # Check if user has an active subscription (if required)
      next unless user_can_receive_alerts?(preference.user)

      # Send email notification
      TradeNotificationMailer.trade_alert(preference.user, trade).deliver_later

      # Log the notification (in a real app, you might want to track this)
      Rails.logger.info "Sent trade alert to #{preference.user.email} for trade #{trade.id}"
    end
  end

  private

  def self.user_can_receive_alerts?(user)
    # For now, allow all users. In a real app, you might check subscription status
    # return user.user_subscriptions.active.exists?
    true
  end
end
