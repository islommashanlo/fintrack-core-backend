# frozen_string_literal: true

class FilingDigestMailer < ApplicationMailer
  def daily(batch, delivery_ids)
    @batch = batch
    @deliveries = batch.user.alert_deliveries.where(id: delivery_ids).includes(:filing, :insider_transaction, :insider_cluster_snapshot, alert_rule: :follow).order(:id).to_a
    ids = @deliveries.filter_map(&:insider_cluster_snapshot).flat_map { |snapshot| snapshot.filing_ids.first(20) }
    @cluster_sources = Filing.where(id: ids).index_by(&:id)
    @unsubscribe_url = EmailUnsubscribe.url(batch.user)
    headers["List-Unsubscribe"] = "<#{@unsubscribe_url}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    mail to: batch.user.email_address, subject: "Your SEC filing digest for #{batch.local_date}"
  end
end
