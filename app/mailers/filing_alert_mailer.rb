# frozen_string_literal: true

class FilingAlertMailer < ApplicationMailer
  def news_item(delivery)
    @news = delivery.news_alert_snapshot
    @watchlist_evidence = if delivery.alert_rule.scope == "watchlist"
      Api::V1::WatchlistFilingEvidenceSerializer.new(ids: [ delivery.id ], channel: "email").render(delivery.id)
    end
    user = delivery.alert_rule.user
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    mail to: user.email_address, subject: NewsAlertText.subject(@watchlist_evidence ? "your watchlist" : delivery.alert_rule.follow.target_key)
  end

  def new_filing(delivery)
    @delivery = delivery
    @filing = delivery.filing
    @follow = delivery.alert_rule.follow
    @watchlist_evidence = if delivery.alert_rule.scope == "watchlist"
      Api::V1::WatchlistFilingEvidenceSerializer.new(ids: [ delivery.id ], channel: "email").render(delivery.id)
    end
    profile = @watchlist_evidence ? "your watchlist" : @follow.target_key
    user = delivery.alert_rule.user
    @transaction = delivery.insider_transaction
    @cluster = delivery.insider_cluster_snapshot
    @position_change = delivery.institutional_change_snapshot
    @institutional_sources = @position_change ? InstitutionalReport.where(id: @position_change.evidence_report_ids.first(20)).includes(:filing).to_a : []
    @cluster_sources = @cluster ? Filing.where(id: @cluster.filing_ids.first(20)).order(:id).to_a : []
    headers["List-Unsubscribe"] = "<#{EmailUnsubscribe.url(user)}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    subject = @transaction ? "Reported insider transaction for #{profile}" : "New SEC filing for #{profile}"
    subject = "Reported insider cluster for #{profile}" if @cluster
    subject = "Reported 13F position change for #{profile}" if @position_change
    mail to: user.email_address, subject:
  end
end
