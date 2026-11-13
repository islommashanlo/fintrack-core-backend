# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Watchlist filing email" do
  include ApiAccounts
  include OpenapiResponses
  around { |example| travel_to(Time.utc(2026, 11, 13, 11)) { example.run } }
  let(:user) { create(:user, password: "password123") }

  def follow(type: "Ticker", key: "ACME")
    create(:follow, user:, target_type: type, target_key: key, skip_default_alert_rule: true)
  end

  def activate(frequency: "daily_digest")
    consent_email(user)
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", trigger: "new_filing",
      channels: [ "email" ], frequency:, active: true }, headers: api_headers, as: :json
    expect(response).to have_http_status(:created)
    expect_documented_response(path: "/alert-rules", method: :post)
    user.alert_rules.find(response.parsed_body.dig("data", "id"))
  end

  def source
    create(:filing, issuer_ticker: "ACME", filed_at: Time.current)
  end

  def events(**parameters)
    get api_v1_alert_events_path, params: { scope: "watchlist", **parameters }
    expect(response).to have_http_status(:ok)
    expect_documented_response(path: "/alert-events", method: :get)
    response.parsed_body.fetch("data")
  end

  it "deduplicates overlap, sends one local-time digest and retains private matched-entity history" do
    issuer = follow
    person = follow(type: "Insider", key: "0000000011")
    activate
    filing = source
    create(:insider_transaction, filing:, insider_cik: person.target_key)
    2.times { AlertEvaluator.call(filing) }
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(0)
    expect(WatchlistFilingMembership.count).to eq(2)
    expect(WatchlistFilingMembership.pluck(:in_app_notification_id)).to all(be_nil)
    expect(AlertDigestPlanner.call(user:)).to be_nil
    WatchlistMembership.remove(user:, id: issuer.id)
    travel 1.hour
    batch = AlertDigestPlanner.call(user:)
    expect(batch.alert_deliveries.count).to eq(1)
    expect { SendAlertDigestJob.perform_now(batch.id) }.to change { ActionMailer::Base.deliveries.length }.by(1)
    expect { SendAlertDigestJob.perform_now(batch.id) }.not_to change { ActionMailer::Base.deliveries.length }
    mail = ActionMailer::Base.deliveries.last
    [ mail.html_part.body.decoded, mail.text_part.body.decoded ].each do |body|
      expect(body).to include("your watchlist", "ACME", person.target_key, filing.sec_url, "Not investment advice")
    end
    expect(mail["List-Unsubscribe-Post"].value).to eq("List-Unsubscribe=One-Click")
    event = events.sole
    expect(event).to include("status" => "sent", "entity" => { "type" => "watchlist", "key" => nil },
      "matched_entities_total_count" => 2, "matched_entities_truncated" => false)
    post api_v1_alert_event_read_path(event.fetch("id")), headers: api_headers
    expect(response).to have_http_status(:ok)
    expect(events.sole.fetch("read_at")).to be_present
    get alerts_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("All watched entities")
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it "never revives a removed membership epoch or adds witnesses on re-evaluation" do
    member = follow
    activate
    filing = source
    AlertEvaluator.call(filing)
    epoch = WatchlistFilingMembership.sole.followed_at
    WatchlistMembership.remove(user:, id: member.id)
    travel 1.second
    WatchlistMembership.add(user:, target: FollowTarget::Target.new("Ticker", "ACME", "ACME"))
    AlertEvaluator.call(filing)
    expect(AlertDelivery.count).to eq(1)
    expect(WatchlistFilingMembership.count).to eq(1)
    expect(WatchlistFilingMembership.sole.followed_at).to eq(epoch)
    travel 1.hour
    expect(AlertDigestPlanner.call(user:)).to be_nil
    expect(AlertDeliveryPolicy.eligible?(AlertDelivery.sole, user:, frequency: "daily_digest")).to be(false)
  end

  %w[consent membership source revision pause time_zone].each do |change|
    it "rechecks #{change} after a digest has already been claimed" do
      member = follow
      rule = activate
      filing = source
      AlertEvaluator.call(filing)
      travel 1.hour
      batch = AlertDigestPlanner.call(user:)
      expect(batch).to be_present
      case change
      when "consent" then NotificationPreferences.update(user:, attributes: { email_enabled: false })
      when "membership" then WatchlistMembership.remove(user:, id: member.id)
      when "source" then filing.update!(parse_status: "failed")
      when "revision" then rule.setting.update!(revision: rule.setting.revision + 1)
      when "pause" then AlertRuleControl.update(user:, id: rule.id, attributes: { active: false })
      when "time_zone" then NotificationPreferences.update(user:, attributes: { time_zone: "UTC" })
      end
      expect { SendAlertDigestJob.perform_now(batch.id) }.not_to change { ActionMailer::Base.deliveries.length }
      expect(batch.reload.status).to eq("canceled")
      expect(AlertDelivery.sole.status).to eq("pending")
    end
  end

  it "publishes verified Pro instant email with bounded evidence and idempotent delivery" do
    with_billing_config do
      bind_billing_customer(user)
      apply_billing_event
      members = 21.times.map { |i| follow(type: "Insider", key: format("%010d", i + 1)) }
      activate(frequency: "instant")
      filing = source
      members.each_with_index { |member, i| create(:insider_transaction, filing:, insider_cik: member.target_key, owner_seq: i + 1) }
      AlertEvaluator.call(filing)
      delivery = AlertDelivery.sole
      expect(WatchlistFilingMembership.count).to eq(21)
      expect { SendAlertJob.perform_now(delivery.id) }.to change { ActionMailer::Base.deliveries.length }.by(1)
      expect { SendAlertJob.perform_now(delivery.id) }.not_to change { ActionMailer::Base.deliveries.length }
      mail = ActionMailer::Base.deliveries.last
      expect(mail.subject).to eq("New SEC filing for your watchlist")
      expect(mail.text_part.body.decoded).to include("Additional captured matches", filing.sec_url)
      expect(mail.text_part.body.decoded).not_to include(members.last.target_key)
      expect(events.sole).to include("matched_entities_total_count" => 21, "matched_entities_truncated" => true)
      AlertEvaluator.call(filing)
      expect(AlertDelivery.count).to eq(1)
      expect(WatchlistFilingMembership.count).to eq(21)
    end
  end

  it "keeps email and in-app evidence separate while sharing one logical rule slot" do
    follow
    activate
    AlertRuleControl.create(user:, attributes: { scope: "watchlist", channel: "in_app", event_type: "new_filing", active: true })
    AlertEvaluator.call(source)
    expect(AlertDelivery.count).to eq(1)
    expect(InAppNotification.count).to eq(1)
    expect(WatchlistFilingMembership.where.not(alert_delivery_id: nil).count).to eq(1)
    expect(WatchlistFilingMembership.where.not(in_app_notification_id: nil).count).to eq(1)
    expect(AlertRuleQuota.count(user)).to eq(1)
    witness = WatchlistFilingMembership.find_by!(alert_delivery_id: AlertDelivery.sole.id)
    expect do
      ApplicationRecord.transaction(requires_new: true) { witness.update_columns(in_app_notification_id: InAppNotification.sole.id) }
    end.to raise_error(ActiveRecord::ReadOnlyRecord)
    attrs = witness.attributes.except("id").merge("in_app_notification_id" => InAppNotification.sole.id)
    expect do
      ApplicationRecord.transaction(requires_new: true) { WatchlistFilingMembership.insert_all!([ attrs ]) }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "rejects Free instant delivery and unadvertised watchlist triggers" do
    follow
    consent_email(user)
    api_login(user)
    post api_v1_alert_rules_path, params: { scope: "watchlist", channels: [ "email" ], frequency: "instant", active: true },
      headers: api_headers, as: :json
    expect(response).to have_http_status(:payment_required)
    post api_v1_alert_rules_path, params: { scope: "watchlist", trigger: "unsupported", channels: [ "email" ], active: true },
      headers: api_headers, as: :json
    expect(response).to have_http_status(:bad_request)
  end
  it "isolates same-entity accounts in history, read-all and deletion" do
    follow
    activate
    other = create(:user, email_address: "other-email@example.com")
    consent_email(other)
    create(:follow, user: other, skip_default_alert_rule: true)
    AlertRuleControl.create(user: other, attributes: { scope: "watchlist", channel: "email", event_type: "new_filing", active: true })
    filing = source
    AlertEvaluator.call(filing)
    own_event = events.sole
    foreign = other.alert_deliveries.sole
    expect(AlertDelivery.count).to eq(2)
    post api_v1_alert_events_read_all_path, headers: api_headers
    expect(response).to have_http_status(:ok)
    expect(AlertEventState.where(alert_delivery_id: foreign.id)).not_to exist
    expect(events.sole.fetch("id")).to eq(own_event.fetch("id"))
    AccountNotificationCleanup.call(user)
    user.destroy!
    expect(WatchlistFilingMembership.sole.user_id).to eq(other.id)
    expect(AlertDelivery.sole.id).to eq(foreign.id)
    expect(filing.reload.parse_status).to eq("parsed")
  end

  it "requires explicit email consent before watchlist email activation" do
    follow
    api_login(user)
    expect do
      post api_v1_alert_rules_path, params: { scope: "watchlist", channels: [ "email" ], active: true },
        headers: api_headers, as: :json
    end.not_to change(AlertRule, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ActionMailer::Base.deliveries).to be_empty
  end
end
