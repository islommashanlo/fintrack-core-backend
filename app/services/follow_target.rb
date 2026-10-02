# frozen_string_literal: true

# Resolves a public profile into the stable key stored by a follow. Tickers do
# not have a table yet, so the key is their normalized ticker symbol.
class FollowTarget
  Target = Data.define(:type, :key, :label)

  def initialize(type:, key:)
    @type = type.to_s
    @key = key.to_s.strip
  end

  def resolve
    case @type
    when "Insider"
      resolve_insider
    when "InstitutionalFiler"
      resolve_institution
    when "Ticker"
      resolve_ticker
    end
  rescue ArgumentError
    nil
  end

  private

  def resolve_insider
    cik = Cik.normalize(@key)
    row = InsiderTransaction.joins(:filing)
      .where(insider_cik: cik, filings: { parse_status: "parsed" })
      .order("filings.filed_at DESC NULLS LAST")
      .pick(:insider_name)
    row.present? ? Target.new("Insider", cik, row) : nil
  end

  def resolve_institution
    filer = InstitutionalFiler.find_by(cik: Cik.normalize(@key))
    filer && Target.new("InstitutionalFiler", filer.cik, filer.name)
  end

  def resolve_ticker
    ticker = @key.upcase
    return unless ticker.match?(/\A[A-Z0-9.-]+\z/)

    issuer = TickerProfile.new(ticker:).issuer
    issuer && Target.new("Ticker", ticker, issuer["issuer_name"].presence || ticker)
  end
end
