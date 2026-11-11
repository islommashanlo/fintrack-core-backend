# frozen_string_literal: true

class ClusterAlertText
  def self.render(snapshot)
    direction = snapshot.transaction_code == "P" ? "purchases" : "sales"
    issuer = snapshot.issuer_ticker.presence || snapshot.issuer_cik
    text = "#{snapshot.insider_count} first-listed insiders reported open-market #{direction} for #{issuer} in the #{snapshot.window_days}-day window ending #{snapshot.window_end.utc.iso8601}"
    text += " (reported value $#{snapshot.total_value.to_s('F')})" if snapshot.total_value
    "#{text}."
  end
end
