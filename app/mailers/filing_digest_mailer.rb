# frozen_string_literal: true

class FilingDigestMailer < ApplicationMailer
  def daily(batch, delivery_ids)
    @batch = batch
    @deliveries = batch.user.alert_deliveries.where(id: delivery_ids).includes(:filing, :insider_transaction, :insider_cluster_snapshot, :news_alert_snapshot,
      institutional_change_snapshot: :institutional_filer, alert_rule: :follow).order(:id).to_a
    ids = @deliveries.filter_map(&:insider_cluster_snapshot).flat_map { |snapshot| snapshot.filing_ids.first(20) }
    @cluster_sources = Filing.where(id: ids).index_by(&:id)
    reports = @deliveries.filter_map(&:institutional_change_snapshot).flat_map { |snapshot| snapshot.evidence_report_ids.first(20) }
    @institutional_sources = InstitutionalReport.where(id: reports).includes(:filing).index_by(&:id)
    @unsubscribe_url = EmailUnsubscribe.url(batch.user)
    headers["List-Unsubscribe"] = "<#{@unsubscribe_url}>"
    headers["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    @has_news = @deliveries.any?(&:news_alert_snapshot_id)
    subject = @has_news ? "Your FilingsIntel alert digest for #{batch.local_date}" : "Your SEC filing digest for #{batch.local_date}"
    mail to: batch.user.email_address, subject:
  end
end
