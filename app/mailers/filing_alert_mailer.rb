# frozen_string_literal: true

class FilingAlertMailer < ApplicationMailer
  def news_item(delivery)
    @news = delivery.news_alert_snapshot
    user = delivery.alert_rule.follow.user
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    mail to: user.email_address, subject: NewsAlertText.subject(delivery.alert_rule.follow.target_key)
  end

  def new_filing(delivery)
    @delivery = delivery
    @filing = delivery.filing
    @follow = delivery.alert_rule.follow
    @transaction = delivery.insider_transaction
    @cluster = delivery.insider_cluster_snapshot
    @position_change = delivery.institutional_change_snapshot
    @institutional_sources = @position_change ? InstitutionalReport.where(id: @position_change.evidence_report_ids.first(20)).includes(:filing).to_a : []
    @cluster_sources = @cluster ? Filing.where(id: @cluster.filing_ids.first(20)).order(:id).to_a : []
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(@follow.user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    subject = @transaction ? "Reported insider transaction for #{@follow.target_key}" : "New SEC filing for #{@follow.target_key}"
    subject = "Reported insider cluster for #{@follow.target_key}" if @cluster
    subject = "Reported 13F position change for #{@follow.target_key}" if @position_change
    mail to: @follow.user.email_address, subject:
  end
end
