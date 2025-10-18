# frozen_string_literal: true

class TradeNotificationMailer < ApplicationMailer
  # Subject can be set in your I18n file at config/locales/en.yml
  # with the following lookup:
  #
  #   en.trade_notification_mailer.trade_alert.subject
  #
  def trade_alert(user, trade)
    @user = user
    @trade = trade
    @greeting = "Hi #{user.email}"

    mail to: user.email, subject: "New Trade Alert: #{trade.asset_name} (#{trade.ticker})"
  end
end
