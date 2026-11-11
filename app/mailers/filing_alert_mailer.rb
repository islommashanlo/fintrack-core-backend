# frozen_string_literal: true

class FilingAlertMailer < ApplicationMailer
  def new_filing(delivery)
    @delivery = delivery
    @filing = delivery.filing
    @follow = delivery.alert_rule.follow
    @transaction = delivery.insider_transaction
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(@follow.user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    subject = @transaction ? "Reported insider transaction for #{@follow.target_key}" : "New SEC filing for #{@follow.target_key}"
    mail to: @follow.user.email_address, subject:
  end
end
