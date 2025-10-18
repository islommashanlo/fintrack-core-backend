# Preview all emails at http://localhost:3000/rails/mailers/trade_notification_mailer_mailer
class TradeNotificationMailerPreview < ActionMailer::Preview

  # Preview this email at http://localhost:3000/rails/mailers/trade_notification_mailer_mailer/trade_alert
  def trade_alert
    TradeNotificationMailer.trade_alert
  end

end
