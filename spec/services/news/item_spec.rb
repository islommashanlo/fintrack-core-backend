# frozen_string_literal: true

require "rails_helper"

RSpec.describe News::Item do
  let(:entity) { News::Entity.new(role: "issuer", id: 123) }

  it "retains only bounded metadata and exact links without resolving or fetching anything" do
    item = news_item(entities: [ entity ])
    expect(item.url).to eq("https://news.example.invalid/stories/meeting?edition=morning")
    expect(item.content.keys).to contain_exactly(:source, :title, :url, :published_at, :kind)
    expect(item.entities).to eq([ entity ])
    expect(item.title).to be_frozen
    expect(WebMock).not_to have_requested(:get, /https?:/)
  end

  it "rejects invalid text, links, timestamps, kinds and entity lists" do
    [ { title: " " }, { source: nil }, { title: "x" * 501 }, { source: "x" * 201 },
      { title: "unsafe\nheadline" }, { url: "javascript:alert(1)" }, { url: "http://example.invalid/story" },
      { url: "/relative" }, { url: "https://user:secret@example.invalid/story" }, { url: "https://" },
      { url: "https://example.invalid/" + "x" * 2048 }, { published_at: Date.new(2026, 11, 10) },
      { published_at: "2026-11-10" }, { kind: "prediction" }, { entities: [] }, { entities: [ entity ] * 2 },
      { entities: [ { role: "issuer", id: 123 } ] } ].each do |change|
      expect { news_item(entities: [ entity ], **change) }.to raise_error(News::Provider::InvalidResponse)
    end
    expect do
      news_item(entities: [ entity ], body: "Full article text")
    end.to raise_error(ArgumentError)
  end

  it "normalizes timestamp precision without mutating the caller's time or metadata" do
    timestamp = Time.iso8601("2026-11-10T12:30:00.123456789+03:00")
    item = news_item(entities: [ entity ], published_at: timestamp)
    expect(item.published_at.iso8601(6)).to eq("2026-11-10T09:30:00.123456Z")
    expect(timestamp.utc_offset).to eq(3.hours)
  end

  it "retains restricted or marked-up source labels without making them publishable" do
    item = news_item(entities: [ entity ], title: "Strong Buy example headline")
    expect(item.title).to eq("Strong Buy example headline")
    expect(item.suppression_reason).to eq("restricted_language")
    expect(news_item(entities: [ entity ], source: "<b>Example</b>").suppression_reason).to eq("markup")
  end

  it "restricts canonical entity references to typed positive local record IDs" do
    [ { role: "User", id: 1 }, { role: "issuer", id: "1" }, { role: "fund", id: -1 } ].each do |values|
      expect { News::Entity.new(**values) }.to raise_error(News::Provider::InvalidResponse)
    end
    expect(News::Entity.new(role: "person", id: 1).entity_type).to eq("Filer")
    expect(News::Entity.new(role: "fund", id: 1).entity_type).to eq("InstitutionalFiler")
  end

  it "keeps the default provider disabled" do
    provider = News::Provider::Disabled.new
    expect(provider.key).to eq("disabled")
    expect { provider.items(entity:, from: 1.day.ago, to: Time.current) }
      .to raise_error(News::Provider::NotConfigured)
  end
end
