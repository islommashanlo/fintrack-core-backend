# frozen_string_literal: true

class FilingAlertMailer < ApplicationMailer
  def new_filing(delivery)
    @delivery = delivery
    @filing = delivery.filing
    @follow = delivery.alert_rule.follow
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(@follow.user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    mail to: @follow.user.email_address, subject: "New SEC filing for #{@follow.target_key}"
  end
end
