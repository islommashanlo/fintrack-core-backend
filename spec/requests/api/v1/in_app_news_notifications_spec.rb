# frozen_string_literal: true

require "rails_helper"

RSpec.describe "In-app news notifications" do
  include ApiAccounts
  around { |example| travel_to(Time.utc(2026, 11, 12, 11)) { with_api_csrf_protection { example.run } } }
  let(:user) { create(:user, password: "password123") }
  let(:fund) { news_entity(role: "fund") }
  before { approve_fixture_news }

  def pro
    allow(Billing::Entitlements).to receive(:pro?).and_call_original
    allow(Billing::Entitlements).to receive(:pro?).with(user).and_return(true)
    allow(Billing::Entitlements).to receive(:pro_user_ids).and_return(User.where(id: user.id).select(:id))
  end

  def rule(entity: fund, conditions: {}, frequency: "daily_digest")
    type, key = case entity.role
    when "fund" then [ "InstitutionalFiler", InstitutionalFiler.find(entity.id).cik ]
    when "person" then [ "Insider", Filer.find(entity.id).cik ]
    else [ "Ticker", "ACME" ]
    end
    follow = create(:follow, user:, target_type: type, target_key: key, followed_at: 1.year.ago, skip_default_alert_rule: true)
    record = AlertRuleControl.create(user:, follow_id: follow.id,
      attributes: { channel: "in_app", event_type: "news", active: true, frequency:, conditions: NewsAlertConditions.normalize(conditions) }).rule
    record.setting.update!(enabled_at: 1.year.ago)
    record
  end

  def list(**parameters)
    get api_v1_notifications_path, params: parameters
    response.parsed_body.fetch("data")
  end

  it "creates typed API rules with Pro instant gating and no email consent or fabricated SEC provenance" do
    api_login(user)
    follow = create(:follow, user:, target_type: "InstitutionalFiler", target_key: InstitutionalFiler.find(fund.id).cik, skip_default_alert_rule: true)
    values = { follow_id: follow.id, trigger: "news", channels: [ "in_app" ], frequency: "instant", active: true,
      conditions: { kinds: [ "press_release" ], providers: [ "fixture" ], source: "Fictional Fund Press Office" } }
    post api_v1_alert_rules_path, params: values, headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    pro
    post api_v1_alert_rules_path, params: values, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    item = store_news(entities: [ fund ], index: 1, published_at: Time.current)
    NewsAlertEvaluator.call(item)
    data = list.sole
    expect(data).to include("trigger" => "news", "historical_filing_notice" => false, "news_available" => true)
    %w[accession sec_url form_type filed_at accepted_at ingested_at data_age_days].each { |key| expect(data.fetch(key)).to be_nil }
    expect(data.fetch("news")).to include("title" => item.title, "url" => item.url)
    expect(InAppNotification.sole.filing_id).to be_nil
    expect(AlertDelivery.count).to eq(0)
    expect(user.notification_preference).to be_nil
    expect(SendAlertJob).not_to have_been_enqueued
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "shares immutable snapshots across channels and deduplicates each rule/story" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    target = rule
    consent_email(user)
    email = AlertRuleControl.create(user:, follow_id: target.follow_id, attributes: { event_type: "news", active: true }).rule
    email.setting.update!(enabled_at: 1.year.ago)
    item = store_news(entities: [ fund ])
    2.times { NewsAlertEvaluator.call(item) }
    expect(InAppNotification.count).to eq(1)
    expect(AlertDelivery.count).to eq(1)
    snapshot = NewsAlertSnapshot.sole
    expect(InAppNotification.sole.news_alert_snapshot_id).to eq(AlertDelivery.sole.news_alert_snapshot_id)
    expect(AlertRuleQuota.count(user)).to eq(1)
    expect { snapshot.update!(title: "Changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    row = InAppNotification.sole
    expect do
      InAppNotification.transaction(requires_new: true) { InAppNotification.insert_all!([ row.attributes.except("id") ]) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "matches canonical issuer, person and fund mentions and enforces exact conditions" do
    pro
    api_login(user)
    issuer, = company_news_identity
    person = news_entity(role: "person")
    [ issuer, person ].each { |entity| rule(entity:, frequency: "instant") }
    target = rule(frequency: "instant", conditions: { "kinds" => [ "press_release" ] })
    rejected = store_news(entities: [ fund ])
    selected = store_news(entities: [ issuer, person, fund ], index: 1)
    NewsAlertEvaluator.call(rejected)
    NewsAlertEvaluator.call(selected)
    expect(target.in_app_notifications.pluck(:news_item_id)).to eq([ selected.id ])
    expect(list.pluck("entity").pluck("type")).to match_array(%w[issuer person fund])
  end

  it "keeps daily news pending until local 07:00 without enabling email" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    rule
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    expect(list).to be_empty
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(list.size).to eq(1)
    expect(user.reload.notification_preference.email_enabled?).to be(false)
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "rechecks publication approval before counts and reads without erasing history" do
    pro
    api_login(user)
    rule(frequency: "instant")
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    row = InAppNotification.sole
    expect(list.size).to eq(1)
    allow(ENV).to receive(:fetch).with("NEWS_PUBLIC_PROVIDERS", "").and_return("")
    expect(list).to be_empty
    get api_v1_notifications_summary_path
    expect(response.parsed_body.dig("data", "total_count")).to eq(0)
    post api_v1_notification_read_path(row), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    post api_v1_notifications_read_all_path, headers: api_headers, as: :json
    expect(response.parsed_body.dig("data", "updated_count")).to eq(0)
    expect(row.reload.read_at).to be_nil
    expect(NewsAlertSnapshot.count).to eq(1)
  end

  it "suppresses unpublished stories on revocation and rejects changed canonical source content" do
    NotificationPreferences.update(user:, attributes: { time_zone: "America/New_York" })
    api_login(user)
    rule
    item = store_news(entities: [ fund ])
    NewsAlertEvaluator.call(item)
    NewsItem.where(id: item.id).update_all(title: "Changed source headline")
    travel 1.hour
    PublishInAppNotificationsJob.perform_now
    expect(InAppNotification.sole.published_at).to be_nil
    expect(list).to be_empty
  end

  it "never matches unapproved, suppressed, future or pre-activation stories" do
    pro
    api_login(user)
    target = rule(frequency: "instant")
    [ store_news(entities: [ fund ], provider: "private"), store_news(entities: [ fund ], title: "Strong Buy example"),
      store_news(entities: [ fund ], observed_at: 1.day.from_now) ].each { |item| NewsAlertEvaluator.call(item) }
    target.setting.update!(enabled_at: Time.current)
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    expect(InAppNotification.count).to eq(0)
  end

  it "preserves published history after unfollow but still requires the same canonical entity" do
    pro
    api_login(user)
    issuer, = company_news_identity
    target = rule(entity: issuer, frequency: "instant")
    NewsAlertEvaluator.call(store_news(entities: [ issuer ]))
    WatchlistMembership.remove(user:, id: target.follow_id)
    expect(list.size).to eq(1)
    different = create(:filer, filer_type: "issuer")
    create(:filing, issuer_cik: different.cik, issuer_ticker: "ACME", filed_at: Time.current, ingested_at: Time.current)
    expect(list).to be_empty
  end

  it "isolates users, keeps acknowledgement idempotent and cleans news notifications on account deletion" do
    pro
    api_login(user)
    rule(frequency: "instant")
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    row = InAppNotification.sole
    other = create(:user, email_address: "other@example.com", password: "password123")
    api_login(other)
    expect(list).to be_empty
    post api_v1_notification_read_path(row), headers: api_headers, as: :json
    expect(response).to have_http_status(:not_found)
    api_login(user)
    2.times do
      post api_v1_notification_read_path(row), headers: api_headers, as: :json
      expect(response).to have_http_status(:ok)
    end
    expect(row.reload.read_at).not_to be_nil
    delete api_v1_me_path, params: { current_password: "password123" }, headers: api_headers, as: :json
    expect(response).to have_http_status(:no_content)
    expect(InAppNotification.count).to eq(0)
    expect(NewsItem.count).to eq(1)
  end

  it "pins issuer identity for a cursor when a backdated mapping filing arrives later" do
    pro
    api_login(user)
    issuer, = company_news_identity
    rule(entity: issuer, frequency: "instant")
    2.times { NewsAlertEvaluator.call(store_news(entities: [ issuer ])) }
    list(limit: 1)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    different = create(:filer, filer_type: "issuer")
    create(:filing, issuer_cik: different.cik, issuer_ticker: "ACME", filed_at: 1.hour.ago, ingested_at: Time.current)
    expect(list(limit: 1, cursor:).size).to eq(1)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    expect(list).to be_empty
  end

  it "rejects mixed news/filing source shapes and preserves source-bound cursors" do
    pro
    api_login(user)
    rule(frequency: "instant")
    2.times { NewsAlertEvaluator.call(store_news(entities: [ fund ])) }
    list(limit: 1)
    cursor = response.parsed_body.dig("meta", "next_cursor")
    NewsAlertEvaluator.call(store_news(entities: [ fund ]))
    expect(list(limit: 1, cursor:).size).to eq(1)
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    row = InAppNotification.first
    filing = create(:filing)
    row.filing = filing
    expect(row).not_to be_valid
    expect do
      InAppNotification.transaction(requires_new: true) { row.update_columns(filing_id: filing.id) }
    end.to raise_error(ActiveRecord::StatementInvalid, /in_app_notification_source/)
  end
end
