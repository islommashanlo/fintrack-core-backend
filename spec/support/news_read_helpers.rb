# frozen_string_literal: true

module NewsReadHelpers
  def store_news(entities:, provider: "fixture", observed_at: Time.current, **attributes)
    payload = news_item(entities:, provider_item_id: "story-#{NewsItem.count + 1}", **attributes)
    News::Ingest.call(provider:, items: [ payload ], observed_at:)
    NewsItem.find_by!(provider:, provider_item_id: payload.provider_item_id)
  end

  def approve_fixture_news
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("fixture")
  end

  def company_news_identity(ticker: "ACME", **attributes)
    issuer = create(:filer, filer_type: "issuer")
    filing = create(:filing, issuer_cik: issuer.cik, issuer_ticker: ticker,
                    filed_at: Time.utc(2026, 11, 1), **attributes)
    [ News::Entity.new(role: "issuer", id: issuer.id), filing ]
  end
end

RSpec.configure do |config|
  config.include NewsReadHelpers
end
