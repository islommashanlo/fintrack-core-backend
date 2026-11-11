# frozen_string_literal: true

class FilingAlertMailer < ApplicationMailer
  def new_filing(delivery)
    @delivery = delivery
    @filing = delivery.filing
    @follow = delivery.alert_rule.follow
    @transaction = delivery.insider_transaction
    @cluster = delivery.insider_cluster_snapshot
    @cluster_sources = @cluster ? Filing.where(id: @cluster.filing_ids.first(20)).order(:id).to_a : []
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(@follow.user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    subject = @transaction ? "Reported insider transaction for #{@follow.target_key}" : "New SEC filing for #{@follow.target_key}"
    subject = "Reported insider cluster for #{@follow.target_key}" if @cluster
    mail to: @follow.user.email_address, subject:
  end
end
