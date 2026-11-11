# frozen_string_literal: true

class TransactionAlertText
  def self.render(transaction)
    action = transaction.open_market? ? "an open-market #{transaction.direction}" : "transaction code #{transaction.transaction_code || 'not provided'}"
    amount = transaction.shares&.to_s("F") || "an unreported quantity of"
    issuer = transaction.issuer_ticker.presence || transaction.issuer_cik
    text = "#{transaction.insider_name} reported #{action} of #{amount} units of #{transaction.security_title} for #{issuer}"
    text += " (reported value $#{transaction.reported_value.to_s('F')})" if transaction.reported_value
    text += " on #{transaction.transaction_date.iso8601}" if transaction.transaction_date
    "#{text}."
  end
end
