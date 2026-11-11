# frozen_string_literal: true

require "rails_helper"

RSpec.describe News::Ingest do
  let(:now) { Time.utc(2026, 11, 11, 12) }
  let(:issuer) { news_entity }
  let(:item) { news_item(entities: [ issuer ]) }

  def ingest(items, provider: "fixture", observed_at: now)
    described_class.call(provider:, items:, observed_at:)
  end

  it "stores one item and typed issuer/fund/person mentions idempotently without article bodies" do
    entities = [ issuer, news_entity(role: "fund"), news_entity(role: "person") ]
    article = news_item(entities:)
    ingest([ article ])
    before = [ NewsItem.sole.attributes, NewsMention.order(:id).map(&:attributes) ]
    ingest([ article ], observed_at: now + 1.hour)
    expect([ NewsItem.sole.attributes, NewsMention.order(:id).map(&:attributes) ]).to eq(before)
    expect(NewsMention.pluck(:role)).to contain_exactly("issuer", "fund", "person")
    expect(NewsItem.sole).to have_attributes(article.content.merge(observed_at: now))
    expect(NewsItem.column_names).not_to include("body", "content", "article_text")
    expect(enqueued_jobs).to be_empty
    expect(WebMock).not_to have_requested(:get, /https?:/)
  end

  it "adds newly discovered canonical mentions with their own observation time without changing the headline" do
    ingest([ item ])
    fund = news_entity(role: "fund")
    ingest([ news_item(entities: [ issuer, fund ]) ], observed_at: now + 1.day)
    expect(NewsItem.sole.observed_at).to eq(now)
    expect(NewsMention.find_by!(role: "issuer").observed_at).to eq(now)
    expect(NewsMention.find_by!(role: "fund").observed_at).to eq(now + 1.day)
  end

  it "rejects duplicate provider keys before writing and treats other providers independently" do
    expect { ingest([ item, item ]) }.to raise_error(News::Provider::InvalidResponse, /Duplicate/)
    expect(NewsItem.count).to eq(0)
    ingest([ item ])
    ingest([ item ], provider: "another")
    expect(NewsItem.count).to eq(2)
    expect(NewsMention.count).to eq(2)
  end

  it "rejects conflicting content atomically and retains existing records" do
    ingest([ item ])
    changed = news_item(entities: [ issuer ], title: "Changed factual headline")
    other = news_item(entities: [ issuer ], index: 1)
    expect { ingest([ other, changed ]) }.to raise_error(described_class::Conflict)
    expect(NewsItem.count).to eq(1)
    expect(NewsItem.sole.title).to eq(item.title)
    expect(NewsMention.count).to eq(1)
  end

  it "rolls back the full batch for a missing or mismatched canonical entity without creating identities" do
    fund = create(:institutional_filer)
    mismatched = News::Entity.new(role: "person", id: Filer.find(issuer.id).id)
    missing = News::Entity.new(role: "fund", id: fund.id + 99)
    [ mismatched, missing ].each do |entity|
      expect do
        ingest([ item, news_item(entities: [ entity ], index: 1) ])
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(NewsItem.count).to eq(0)
      expect(NewsMention.count).to eq(0)
    end
    expect(Filer.count).to eq(1)
    expect(InstitutionalFiler.count).to eq(1)
  end

  it "preserves suppressed headlines and excludes them from the publishable scope" do
    restricted = news_item(entities: [ issuer ], title: "Buy example shares")
    markup = news_item(entities: [ issuer ], index: 1, title: "<b>Example headline</b>")
    ingest([ restricted, markup ])
    expect(NewsItem.order(:id).pluck(:title)).to eq([ restricted.title, markup.title ])
    expect(NewsItem.publishable).to be_empty
    expect(NewsItem.pluck(:suppression_reason)).to contain_exactly("restricted_language", "markup")
  end

  it "rejects malformed, unbounded and future publication batches before inserting anything" do
    future = news_item(entities: [ issuer ], published_at: now + 1.second)
    [ [ future ], [ item.to_h ], [ item ] * 101, nil ].each do |items|
      expect { ingest(items) }.to raise_error(News::Provider::InvalidResponse)
    end
    expect { ingest([ item ], provider: "../invalid") }.to raise_error(News::Provider::InvalidResponse)
    expect(NewsItem.count).to eq(0)
  end
end
