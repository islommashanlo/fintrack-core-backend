# frozen_string_literal: true

require "rails_helper"

RSpec.describe "News alert matching and delivery" do
  around { |example| travel_to(Time.utc(2026, 11, 11, 12)) { example.run } }
  let(:user) { create(:user) }
  let(:fund) { news_entity(role: "fund") }
  before do
    approve_fixture_news
    consent_email(user)
  end

  it "captures immutable headline and canonical source evidence once per rule/story without a SEC filing" do
    rule = news_rule(user:, entity: fund)
    item = store_news(entities: [ fund ])
    2.times { NewsAlertEvaluator.call(item) }
    snapshot = NewsAlertSnapshot.sole
    expect(snapshot).to have_attributes(news_item_id: item.id, title: item.title, url: item.url, source: item.source,
      published_at: item.published_at, item_observed_at: item.observed_at, role: "fund", cik: InstitutionalFiler.find(fund.id).cik)
    expect(rule.alert_deliveries.sole).to have_attributes(filing_id: nil, news_item_id: item.id, news_alert_snapshot_id: snapshot.id)
    expect { snapshot.update!(title: "Changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(EvaluateNewsAlertsJob).to have_been_enqueued.with(item.id)
    expect(SendAlertJob).not_to have_been_enqueued
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "supports all three canonical follow types and shares a snapshot across users" do
    issuer, = company_news_identity
    person = news_entity(role: "person")
    [ issuer, person, fund ].each { |entity| news_rule(user:, entity:) }
    other = create(:user, email_address: "other@example.com")
    consent_email(other)
    news_rule(user: other, entity: fund)
    item = store_news(entities: [ issuer, person, fund ])
    NewsAlertEvaluator.call(item)
    expect(AlertDelivery.count).to eq(4)
    expect(NewsAlertSnapshot.count).to eq(3)
    expect(AlertDelivery.where(news_item_id: item.id).pluck(:filing_id)).to eq([ nil ] * 4)
  end

  it "applies exact source, kind and provider conditions without overriding publication approval" do
    rule = news_rule(user:, entity: fund, conditions: { "kinds" => [ "press_release" ], "source" => "Fictional Fund Press Office", "providers" => [ "fixture" ] })
    rejected = store_news(entities: [ fund ])
    selected = store_news(entities: [ fund ], index: 1)
    NewsAlertEvaluator.call(rejected)
    NewsAlertEvaluator.call(selected)
    expect(rule.alert_deliveries.pluck(:news_item_id)).to eq([ selected.id ])
    private_item = store_news(entities: [ fund ], provider: "private")
    expect { NewsAlertEvaluator.call(private_item) }.not_to change(AlertDelivery, :count)
  end

  it "rejects sources published before activation, future observations and suppressed headlines" do
    rule = news_rule(user:, entity: fund)
    old = store_news(entities: [ fund ])
    rule.setting.update!(enabled_at: Time.current)
    expect { NewsAlertEvaluator.call(old) }.not_to change(AlertDelivery, :count)
    rule.setting.update!(enabled_at: 1.year.ago)
    future = store_news(entities: [ fund ], observed_at: 1.day.from_now)
    blocked = store_news(entities: [ fund ], title: "Strong Buy example")
    [ future, blocked ].each { |item| expect { NewsAlertEvaluator.call(item) }.not_to change(AlertDelivery, :count) }
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    expect { NewsAlertEvaluator.call(old) }.not_to change(AlertDelivery, :count)
  end

  it "evaluates a later mention without replaying an already matched story" do
    rule = news_rule(user:, entity: fund)
    original = news_entity(role: "person")
    item = store_news(entities: [ original ])
    NewsAlertEvaluator.call(item)
    expect(AlertDelivery.count).to eq(0)
    travel 1.minute
    NewsMention.create!(news_item: item, entity: InstitutionalFiler.find(fund.id), role: "fund", observed_at: Time.current)
    2.times { EvaluateNewsAlertsJob.perform_now(item.id) }
    expect(rule.alert_deliveries.count).to eq(1)
    expect(NewsAlertSnapshot.sole.mention_observed_at).to eq(Time.current)
  end

  it "rechecks publication, wording, canonical source state and rule controls before delivery" do
    rule = news_rule(user:, entity: fund)
    item = store_news(entities: [ fund ])
    NewsAlertEvaluator.call(item)
    delivery = AlertDelivery.sole
    eligible = -> { AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "daily_digest") }
    expect(eligible.call).to be(true)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    expect(eligible.call).to be(false)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("fixture")
    NewsItem.where(id: item.id).update_all(title: "Changed factual source")
    expect(eligible.call).to be(false)
    NewsItem.where(id: item.id).update_all(title: delivery.news_alert_snapshot.title)
    expect(eligible.call).to be(true)
    stub_const("Policy::BannedLanguageScan::BANNED_TERMS", /\bmeeting\b/i)
    expect(eligible.call).to be(false)
    rule.follow.update!(removed_at: Time.current)
    expect(eligible.call).to be(false)
  end

  it "suppresses an issuer delivery after its ticker maps to another issuer" do
    issuer, filing = company_news_identity
    news_rule(user:, entity: issuer)
    item = store_news(entities: [ issuer ])
    NewsAlertEvaluator.call(item)
    replacement = news_entity
    create(:filing, issuer_ticker: "ACME", issuer_cik: Filer.find(replacement.id).cik,
      filed_at: filing.filed_at + 1.day, ingested_at: filing.filed_at + 1.day)
    expect(AlertDeliveryPolicy.eligible?(AlertDelivery.sole, user:, frequency: "daily_digest")).to be(false)
  end

  it "rejects paused, revised and unfollowed rules while keeping the evidence" do
    rule = news_rule(user:, entity: fund)
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    delivery = AlertDelivery.sole
    eligible = -> { AlertDeliveryPolicy.eligible?(delivery, user:, frequency: "daily_digest") }
    expect(eligible.call).to be(true)
    rule.update!(active: false)
    expect(eligible.call).to be(false)
    enable_rule(rule)
    expect(eligible.call).to be(true)
    rule.setting.increment!(:revision)
    expect(eligible.call).to be(false)
    rule.setting.decrement!(:revision)
    rule.follow.update!(removed_at: Time.current)
    expect(eligible.call).to be(false)
    expect(NewsAlertSnapshot.count).to eq(1)
  end

  it "sends factual instant copy only through the test adapter and rechecks paid access and consent" do
    allow(PlanCatalog).to receive(:limit_for).and_call_original
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    issuer, = company_news_identity(ticker: "BUY")
    news_rule(user:, entity: issuer, ticker: "BUY", frequency: "instant")
    item = store_news(entities: [ issuer ], source: "Example & News")
    NewsAlertEvaluator.call(item)
    delivery = AlertDelivery.sole
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("fixture")
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(false)
    expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    allow(PlanCatalog).to receive(:limit_for).with(anything, :instant_alerts).and_return(true)
    user.notification_preference.update!(email_enabled: false)
    expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.size }
    user.notification_preference.update!(email_enabled: true)
    2.times { SendAlertJob.perform_now(delivery.id) }
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to start_with("News headline for")
    expect(Policy::BannedLanguageScan.new.scan_text(mail.subject)).to be_empty
    expect(mail.text_part.body.decoded).to include(item.title, item.url, "External news headline")
    expect(mail.text_part.body.decoded).not_to include("SEC source:", "Accession:")
    expect(mail.html_part.body.decoded).to include("Example &amp; News")
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    expect(delivery.reload.status).to eq("sent")
  end

  it "delivers mixed news and filing digests without inventing filing provenance for news" do
    news_rule(user:, entity: fund)
    item = store_news(entities: [ fund ])
    NewsAlertEvaluator.call(item)
    follow = create(:follow, user:, target_key: "OTHER")
    enable_rule(follow.alert_rule)
    create(:alert_delivery, alert_rule: follow.alert_rule, frequency: "daily_digest")
    travel 1.day
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to start_with("Your FilingsIntel alert digest")
    expect(mail.text_part.body.decoded).to include(item.url, "Headline source:", "SEC source:")
    expect(batch.alert_deliveries.pluck(:status)).to eq(%w[sent sent])
  end

  it "blocks inconsistent news/filing source combinations at the database boundary" do
    news_rule(user:, entity: fund)
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    row = AlertDelivery.sole.attributes.except("id").merge("filing_id" => create(:filing).id)
    expect { AlertDelivery.insert_all!([ row ]) }.to raise_error(ActiveRecord::StatementInvalid, /alert_delivery_source/)
  end
end
