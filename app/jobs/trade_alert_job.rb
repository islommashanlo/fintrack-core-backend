# frozen_string_literal: true

class TradeAlertJob < ApplicationJob
  queue_as :default

  def perform(trade_id)
    trade = Trade.find_by(id: trade_id)
    return unless trade

    NotificationService.send_trade_alerts(trade)
  end
end
