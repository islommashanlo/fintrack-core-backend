# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist news alerts" do
  include ApiAccounts
  include OpenapiResponses
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { news_entity(role: "fund") }
  before { approve_fixture_news }

  def member(entity = fund)
    type, key = case entity.role
    when "fund" then [ "InstitutionalFiler", InstitutionalFiler.find(entity.id).cik ]
    when "person" then [ "Insider", Filer.find(entity.id).cik ]
    else [ "Ticker", "ACME" ]
    end
    create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
  end

  def activate(channel:, frequency: "daily_digest", conditions: {})
    channel == "email" ? consent_email(user) : NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", trigger: "news", channels: [ channel ],
      active: true, frequency:, conditions: }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    expect(response.parsed_body.dig("meta", "watchlist_#{channel}_supported_triggers")).to include("news")
    rule = AlertRule.find(response.parsed_body.dig("data", "id"))
    rule.setting.update!(enabled_at: 1.year.ago)
    rule
  end

  def both(**options)
    %w[email in_app].map { |channel| activate(channel:, **options) }
  end

  def story(entities: [ fund ], **attributes)
    store_news(entities:, published_at: 1.hour.ago, **attributes)
  end

  def notices(**parameters)
    get api_v1_notifications_path, params: parameters
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/notifications", method: :get)
    response.parsed_body.fetch("data")
  end

  it "captures overlapping canonical entities once per story, shares snapshots and delivers a factual digest" do
    issuer, = company_news_identity
    person = news_entity(role: "person")
    [ issuer, person, fund ].each { |entity| member(entity) }
    both
    item = story(entities: [ issuer, person, fund ])
    2.times { NewsAlertEvaluator.call(item) }
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
    expect(NewsAlertSnapshot.count).to eq(3)
    expect(AlertDelivery.sole.news_alert_snapshot_id).to eq(InAppNotification.sole.news_alert_snapshot_id)
    expect(WatchlistNewsMembership.count).to eq(6)
    expect(WatchlistFilingMembership.count).to eq(0)
    expect(AlertRuleQuota.count(user)).to eq(1)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    row = notices.sole
    expect(row.fetch("entity")).to include("type" => "watchlist", "key" => nil)
    expect(row.fetch("matched_entities").pluck("type")).to match_array(%w[issuer person fund])
    %w[accession sec_url form_type filed_at accepted_at ingested_at data_age_days].each { |key| expect(row.fetch(key)).to be_nil }
    expect(row.dig("news", "url")).to eq(item.url)
    batch = AlertDigestPlanner.call(user:)
    SendAlertDigestJob.perform_now(batch.id)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.text_part.body.decoded).to include(item.title, item.url, "Issuer ACME")
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    get api_v1_alert_events_path, params: { scope: "watchlist" }
    expect_documented_response(path: "/alert-events", method: :get)
    expect(response.parsed_body.fetch("data").sole.fetch("matched_entities_total_count")).to eq(3)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "keeps pending delivery eligible while another captured match remains live" do
    person = news_entity(role: "person")
    first = member
    member(person)
    both
    item = story(entities: [ fund, person ])
    NewsAlertEvaluator.call(item)
    WatchlistMembership.remove(user:, id: first.id)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(1)
    expect(notices.sole.fetch("matched_entities_total_count")).to eq(2)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest").count).to eq(1)
  end

  it "does not append new members or re-added epochs to captured story evidence" do
    watched = member
    person = news_entity(role: "person")
    both
    item = story(entities: [ fund, person ])
    NewsAlertEvaluator.call(item)
    evidence = WatchlistNewsMembership.order(:id).map(&:attributes)
    WatchlistMembership.remove(user:, id: watched.id)
    travel 1.second
    WatchlistMembership.add(user:, target: FollowTarget::Target.new(watched.target_type, watched.target_key, "Example"))
    member(person)
    NewsAlertEvaluator.call(item)
    expect(WatchlistNewsMembership.order(:id).map(&:attributes)).to eq(evidence)
    expect(AlertDelivery.count).to eq(1)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
  end

  it "requires a live membership and valid canonical mention on the same captured witness" do
    person = news_entity(role: "person")
    member
    member(person)
    both
    item = story(entities: [ fund, person ])
    NewsAlertEvaluator.call(item)
    delivery = AlertDelivery.sole
    proof = WatchlistNewsMembership.find_by!(alert_delivery_id: delivery.id, news_alert_snapshot_id: delivery.news_alert_snapshot_id)
    WatchlistMembership.remove(user:, id: proof.follow_id)
    other = WatchlistNewsMembership.where(alert_delivery_id: delivery.id).where.not(id: proof.id).sole
    NewsMention.where(id: other.news_alert_snapshot.news_mention_id).update_all(observed_at: Time.current + 1.second)
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
  end

  it "suppresses pending publication and delivery after provider approval is revoked" do
    member
    both
    NewsAlertEvaluator.call(story)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
    expect(AlertDelivery.count).to eq(1)
    expect(NewsAlertSnapshot.count).to eq(1)
  end

  it "rejects changed canonical content without replacing immutable alert evidence" do
    member
    both
    item = story
    NewsAlertEvaluator.call(item)
    original = NewsAlertSnapshot.sole.title
    NewsItem.where(id: item.id).update_all(title: "Changed canonical headline")
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
    expect(NewsAlertSnapshot.sole.title).to eq(original)
  end

  it "delivers verified Pro instant email and in-app news without fabricated SEC provenance" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      member
      both(frequency: "instant", conditions: { kinds: [ "press_release" ], providers: [ "fixture" ], source: "Fictional Fund Press Office" })
      item = story(index: 1)
      NewsAlertEvaluator.call(item)
      expect(notices.sole.dig("news", "title")).to eq(item.title)
      expect(SendAlertJob).to have_been_enqueued.with(AlertDelivery.sole.id)
      2.times { SendAlertJob.perform_now(AlertDelivery.sole.id) }
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      mail = ActionMailer::Base.deliveries.last
      expect(mail.subject).to eq("News headline for your watchlist")
      expect(mail.text_part.body.decoded).to include("Matched your watchlist", item.url)
    end
  end

  it "matches exact conditions and rejects future, unapproved and pre-activation stories" do
    member
    rules = both(conditions: { kinds: [ "press_release" ], providers: [ "fixture" ] })
    [ story, story(index: 1, provider: "private"), story(index: 1, observed_at: 1.day.from_now) ].each { |item| NewsAlertEvaluator.call(item) }
    rules.each { |rule| rule.setting.update!(enabled_at: Time.current) }
    NewsAlertEvaluator.call(story(index: 1))
    expect(AlertDelivery.count).to eq(0)
    expect(InAppNotification.count).to eq(0)
  end

  it "does not treat late observation as publication after a new membership" do
    watched = member
    watched.update!(followed_at: Time.current)
    both
    NewsAlertEvaluator.call(story)
    expect(AlertDelivery.count).to eq(0)
    expect(InAppNotification.count).to eq(0)
  end

  it "rechecks email consent and configuration revisions before pending delivery" do
    member
    rules = both
    NewsAlertEvaluator.call(story)
    NotificationPreferences.update(user:, attributes: { email_enabled: false })
    expect(AlertDeliveryPolicy.scope(user:, frequency: "daily_digest")).to be_empty
    rules.each { |rule| rule.setting.update!(revision: rule.setting.revision + 1) }
    travel 1.hour
    expect(InAppNotificationPublisher.call).to eq(0)
    expect(AlertDigestPlanner.call(user:)).to be_nil
  end

  it "keeps published evidence after unfollow while rechecking ticker identity with cursor ceilings" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      issuer, = company_news_identity
      watched = member(issuer)
      both(frequency: "instant")
      2.times { NewsAlertEvaluator.call(story(entities: [ issuer ])) }
      expect(notices(limit: 1).size).to eq(1)
      cursor = response.parsed_body.dig("meta", "next_cursor")
      WatchlistMembership.remove(user:, id: watched.id)
      expect(notices.size).to eq(2)
      different = create(:filer, filer_type: "issuer")
      create(:filing, issuer_cik: different.cik, issuer_ticker: "ACME", filed_at: 1.hour.ago, ingested_at: Time.current)
      expect(notices(limit: 1, cursor:).size).to eq(1)
      expect(notices).to be_empty
    end
  end

  it "caps displayed identities while storing all matching mentions" do
    issuer, = company_news_identity
    entities = [ issuer, *19.times.map { news_entity(role: "fund") } ]
    entities.each { |entity| member(entity) }
    create(:filing, issuer_cik: Filer.find(issuer.id).cik, issuer_ticker: "ALIAS", filed_at: 1.day.ago)
    create(:follow, user:, target_key: "ALIAS", followed_at: 1.year.ago, skip_default_alert_rule: true)
    both
    NewsAlertEvaluator.call(story(entities:))
    expect(WatchlistNewsMembership.count).to eq(42)
    travel 1.hour
    InAppNotificationPublisher.call
    row = notices.sole
    expect(row.fetch("matched_entities").size).to eq(20)
    expect(row).to include("matched_entities_total_count" => 21, "matched_entities_truncated" => true)
  end

  it "enforces witness ownership, source and destination shape in the database" do
    member
    both
    NewsAlertEvaluator.call(story)
    proof = WatchlistNewsMembership.where.not(alert_delivery_id: nil).sole
    other_user = create(:user, email_address: "foreign-news@example.com")
    foreign_follow = create(:follow, user: other_user, skip_default_alert_rule: true)
    [ { follow_id: foreign_follow.id }, { in_app_notification_id: InAppNotification.sole.id },
      { news_item_id: story.id } ].each do |attributes|
      expect do
        ApplicationRecord.transaction(requires_new: true) { WatchlistNewsMembership.insert_all!([ proof.attributes.except("id").merge(attributes.stringify_keys) ]) }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  it "isolates owners and cleans private news evidence without removing public sources" do
    member
    both
    other = create(:user, email_address: "other-news@example.com")
    consent_email(other)
    create(:follow, user: other, target_type: "InstitutionalFiler", target_key: InstitutionalFiler.find(fund.id).cik, followed_at: 1.year.ago, skip_default_alert_rule: true)
    %w[email in_app].each do |channel|
      rule = AlertRuleControl.create(user: other, attributes: { scope: "watchlist", event_type: "news", channel:, active: true }).rule
      rule.setting.update!(enabled_at: 1.year.ago)
    end
    NewsAlertEvaluator.call(story)
    travel 1.hour
    InAppNotificationPublisher.call
    expect(notices.size).to eq(1)
    post api_v1_notification_read_path(other.in_app_notifications.sole.id), headers: api_headers
    expect(response).to have_http_status(:not_found)
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(WatchlistNewsMembership.pluck(:user_id).uniq).to eq([ other.id ])
    expect(AlertDelivery.sole.alert_rule.user_id).to eq(other.id)
    expect(NewsItem.count).to eq(1)
  end
end
