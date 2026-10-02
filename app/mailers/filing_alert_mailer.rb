# frozen_string_literal: true

class FilingAlertMailer < ApplicationMailer
  def new_filing(delivery)
    @delivery = delivery
    @filing = delivery.filing
    @follow = delivery.alert_rule.follow
    mail to: @follow.user.email_address, subject: "New SEC filing for #{@follow.target_key}"
  end
end
